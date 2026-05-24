defmodule Ourocode.Journal.SourceTransportNormalizer do
  @moduledoc """
  Normalizes raw source transport events for no-loss validation.

  The no-loss comparator intentionally compares canonical normalized events.
  This module is the validation pipeline step that converts raw stdio, SSE, and
  streamable HTTP source records into the same lifecycle event schema before the
  comparator runs.
  """

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.RawProtocolMessage
  alias Ourocode.MCP.Transport.SSE
  alias Ourocode.MCP.Transport.Stdio
  alias Ourocode.MCP.Transport.StdoutJsonlParser
  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.Journal.SourceTransportNormalizer.Context
  alias Ourocode.Journal.SourceTransportNormalizer.HookLifecycleEvent
  alias Ourocode.Journal.SourceTransportNormalizer.RawMetadata

  @type source_event :: map() | LifecycleEvent.t()
  @type normalization_report :: %{
          required(:type) => :source_transport_event_normalization,
          required(:status) => :ok,
          required(:source_event_count) => non_neg_integer(),
          required(:normalized_event_count) => non_neg_integer(),
          required(:transports) => [atom()]
        }

  @spec normalize([source_event()], keyword() | map()) ::
          {:ok, [LifecycleEvent.t() | map()], normalization_report()} | {:error, map()}
  def normalize(source_events, options \\ [])

  def normalize(source_events, options) when is_list(source_events) do
    default_context = Context.from_options(options)

    {result, _next_seq, transports} =
      source_events
      |> Enum.with_index()
      |> Enum.reduce_while({{:ok, []}, Map.fetch!(default_context, :event_seq), MapSet.new()}, fn
        {source_event, source_index}, {{:ok, normalized_events}, next_seq, transports} ->
          context = Context.for_event(source_event, default_context, next_seq)

          case normalize_one(source_event, context) do
            {:ok, events} ->
              events =
                events
                |> List.wrap()
                |> RawMetadata.enrich(source_event)

              next_seq = next_event_seq(events, next_seq)
              transports = add_transports(transports, events, source_event)

              {:cont, {{:ok, normalized_events ++ events}, next_seq, transports}}

            {:error, reason} ->
              {:halt,
               {{:error,
                 %{
                   type: :source_transport_event_normalization,
                   status: :failed,
                   reason: :source_transport_event_normalization_failed,
                   source_index: source_index,
                   transport: RawMetadata.source_transport(source_event),
                   detail: reason
                 }}, next_seq, transports}}
          end
      end)

    case result do
      {:ok, normalized_events} ->
        {:ok, normalized_events,
         %{
           type: :source_transport_event_normalization,
           status: :ok,
           source_event_count: length(source_events),
           normalized_event_count: length(normalized_events),
           transports: transports |> MapSet.to_list() |> Enum.sort()
         }}

      {:error, report} ->
        {:error, report}
    end
  end

  def normalize(_source_events, _options) do
    {:error,
     %{
       type: :source_transport_event_normalization,
       status: :failed,
       reason: :source_events_must_be_list
     }}
  end

  defp normalize_one(%LifecycleEvent{} = event, _context), do: {:ok, [event]}

  defp normalize_one(%{transport: :stdio, line: line}, context) when is_binary(line) do
    case StdoutJsonlParser.parse_protocol_line_detailed(line) do
      {:ok, message} ->
        {:ok, [Stdio.LifecycleNormalizer.normalize_protocol_message(message, context)]}

      :ignore ->
        {:error, :ignored_stdio_line}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_one(%{transport: "stdio", line: line}, context) when is_binary(line) do
    normalize_one(%{transport: :stdio, line: line}, context)
  end

  defp normalize_one(%{transport: :stdio, message: %RawProtocolMessage{} = message}, context) do
    {:ok, [Stdio.LifecycleNormalizer.normalize_protocol_message(message, context)]}
  end

  defp normalize_one(%{transport: :stdio, decoded: decoded}, context) when is_map(decoded) do
    message = RawProtocolMessage.from_decoded(decoded)
    {:ok, [Stdio.LifecycleNormalizer.normalize_protocol_message(message, context)]}
  end

  defp normalize_one(%{transport: :sse, frame: frame}, context) when is_binary(frame) do
    with {:ok, event} when is_map(event) <- SSE.Parser.parse_frame(frame) do
      {:ok, [SSE.LifecycleNormalizer.normalize_parsed_event(event, context)]}
    else
      {:ok, nil} -> {:error, :ignored_sse_frame}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_one(%{transport: "sse", frame: frame}, context) when is_binary(frame) do
    normalize_one(%{transport: :sse, frame: frame}, context)
  end

  defp normalize_one(%{transport: :sse, event: event}, context) when is_map(event) do
    {:ok, [SSE.LifecycleNormalizer.normalize_parsed_event(event, context)]}
  end

  defp normalize_one(%{transport: "sse", event: event}, context) when is_map(event) do
    normalize_one(%{transport: :sse, event: event}, context)
  end

  defp normalize_one(
         %{transport: :streamable_http, status: status, headers: headers, body: body},
         context
       )
       when is_integer(status) and is_list(headers) and is_binary(body) do
    StreamableHTTP.LifecycleNormalizer.normalize_body(status, headers, body, context)
  end

  defp normalize_one(
         %{transport: "streamable_http", status: status, headers: headers, body: body},
         context
       )
       when is_integer(status) and is_list(headers) and is_binary(body) do
    normalize_one(
      %{transport: :streamable_http, status: status, headers: headers, body: body},
      context
    )
  end

  defp normalize_one(%{} = event, context) do
    case HookLifecycleEvent.normalize(event, context) do
      {:ok, lifecycle_event} ->
        {:ok, [lifecycle_event]}

      :error ->
        normalize_lifecycle_event_map(event)
    end
  end

  defp normalize_one(_event, _context), do: {:error, :unsupported_source_transport_event}

  defp normalize_lifecycle_event_map(%{} = event) do
    if normalized_lifecycle_event?(event) do
      {:ok, [event]}
    else
      {:error, :unsupported_source_transport_event}
    end
  end

  defp next_event_seq([], next_seq), do: next_seq

  defp next_event_seq(events, next_seq) do
    events
    |> Enum.map(&(Map.get(&1, :event_seq) || Map.get(&1, "event_seq")))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> next_seq + length(events)
      seqs -> Enum.max(seqs) + 1
    end
  end

  defp add_transports(transports, events, source_event) do
    event_transports =
      events
      |> Enum.map(&(Map.get(&1, :transport) || Map.get(&1, "transport")))
      |> Enum.reject(&is_nil/1)

    event_transports =
      case {event_transports, RawMetadata.source_transport(source_event)} do
        {[], nil} -> []
        {[], transport} -> [transport]
        {transports, _source_transport} -> transports
      end

    Enum.reduce(event_transports, transports, fn transport, acc ->
      MapSet.put(acc, RawMetadata.normalize_transport(transport))
    end)
  end

  defp normalized_lifecycle_event?(%{} = event) do
    Map.has_key?(event, :event_seq) or Map.has_key?(event, "event_seq")
  end
end
