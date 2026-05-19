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

  @type source_event :: map() | LifecycleEvent.t()
  @type normalization_report :: %{
          required(:type) => :source_transport_event_normalization,
          required(:status) => :ok,
          required(:source_event_count) => non_neg_integer(),
          required(:normalized_event_count) => non_neg_integer(),
          required(:transports) => [atom()]
        }

  @default_context %{
    event_seq: 1,
    parent_call_id: "source-transport-validation",
    runtime_source: "source-transport-validation",
    external_ids: %{}
  }

  @raw_metadata_keys %{
    stdio: [
      :transport,
      :transport_type,
      :process_identifier,
      :session_identifier,
      :stream_direction,
      :timestamp_ms,
      :raw_payload_ref
    ],
    sse: [
      :transport,
      :transport_type,
      :endpoint_url,
      :connection_identifier,
      :session_identifier,
      :sse_event_id,
      :sse_event_id_present,
      :sse_event_type,
      :sse_event_type_present,
      :timestamp_ms,
      :received_at_ms,
      :raw_payload_ref,
      :raw_payload_stored?,
      :raw_payload_size_bytes
    ],
    streamable_http: [
      :transport,
      :transport_type,
      :stream_direction,
      :correlation_id,
      :request_id,
      :parent_call_id,
      :method,
      :status,
      :headers,
      :url,
      :timestamp_ms,
      :sent_at_ms,
      :received_at_ms,
      :raw_payload_ref,
      :raw_payload_size_bytes
    ]
  }

  @spec normalize([source_event()], keyword() | map()) ::
          {:ok, [LifecycleEvent.t() | map()], normalization_report()} | {:error, map()}
  def normalize(source_events, options \\ [])

  def normalize(source_events, options) when is_list(source_events) do
    default_context =
      options
      |> options_map()
      |> Map.get(:context, %{})
      |> normalize_context()

    {result, _next_seq, transports} =
      source_events
      |> Enum.with_index()
      |> Enum.reduce_while({{:ok, []}, Map.fetch!(default_context, :event_seq), MapSet.new()}, fn
        {source_event, source_index}, {{:ok, normalized_events}, next_seq, transports} ->
          context = event_context(source_event, default_context, next_seq)

          case normalize_one(source_event, context) do
            {:ok, events} ->
              events =
                events
                |> List.wrap()
                |> enrich_raw_transport_metadata(source_event)

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
                   transport: source_transport(source_event),
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
    case normalize_hook_lifecycle_event(event, context) do
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

  defp normalize_hook_lifecycle_event(%{} = event, context) do
    with {:ok, type} <- hook_lifecycle_type(event),
         hook_id when is_binary(hook_id) and hook_id != "" <- event_value(event, :hook_id),
         source when not is_nil(source) <- event_value(event, :source) do
      source = normalize_source(source)

      {:ok,
       LifecycleEvent.new(
         type,
         hook_lifecycle_attrs(type, event, context, hook_id, source)
       )}
    else
      _not_hook_lifecycle -> :error
    end
  end

  defp hook_lifecycle_type(event) do
    event
    |> event_value(:type)
    |> normalize_type()
    |> case do
      type when type in [:hook_started, :hook_progress] -> {:ok, type}
      type when type in [:hook_response, :hook_completed] -> {:ok, type}
      _type -> :error
    end
  end

  defp hook_lifecycle_attrs(type, event, context, hook_id, source) do
    base_attrs = %{
      event_seq: Map.fetch!(context, :event_seq),
      transport: normalize_transport(event_value(event, :transport)) || :runtime,
      parent_call_id: parent_call_id(event, context),
      source: source,
      runtime_source: runtime_source(event, context, source),
      external_ids: external_ids(event, context),
      occurred_at_ms: occurred_at_ms(event, context),
      hook_id: hook_id,
      payload: event_value(event, :payload),
      raw_event: event
    }

    case type do
      :hook_progress ->
        base_attrs
        |> Map.put(:progress_state, progress_state(event))
        |> Map.put(:ordering_metadata, ordering_metadata(event))

      type when type in [:hook_response, :hook_completed] ->
        base_attrs
        |> Map.put(:status, completion_status(event))
        |> Map.put(:result, completion_result(event))
        |> Map.put(:error, completion_error(event))
        |> Map.put(:completion_metadata, completion_metadata(event))

      _type ->
        base_attrs
    end
  end

  defp event_value(event, key) when is_atom(key) do
    string_key = Atom.to_string(key)

    case Map.fetch(event, key) do
      {:ok, nil} -> Map.get(event, string_key)
      {:ok, value} -> value
      :error -> Map.get(event, string_key)
    end
  end

  defp normalize_type(:hook_response), do: :hook_response
  defp normalize_type(:plugin_hook_response), do: :hook_response
  defp normalize_type(:runtime_hook_response), do: :hook_response
  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(type) when is_binary(type) do
    case String.trim(type) do
      "hook_started" -> :hook_started
      "hook_progress" -> :hook_progress
      "hook_completed" -> :hook_completed
      "hook_response" -> :hook_response
      "plugin_hook_response" -> :hook_response
      "runtime_hook_response" -> :hook_response
      _type -> nil
    end
  end

  defp normalize_type(_type), do: nil

  defp normalize_source(source) when is_binary(source) do
    case String.trim(source) do
      "plugin_runtime" -> :plugin_runtime
      "runtime" -> :runtime
      "hook_lifecycle" -> :hook_lifecycle
      other -> other
    end
  end

  defp normalize_source(source), do: source

  defp parent_call_id(event, context) do
    event_value(event, :parent_call_id) || Map.fetch!(context, :parent_call_id)
  end

  defp runtime_source(event, context, source) do
    event_value(event, :runtime_source) || to_string(source) ||
      Map.fetch!(context, :runtime_source)
  end

  defp external_ids(event, context) do
    case event_value(event, :external_ids) do
      external_ids when is_map(external_ids) ->
        context
        |> Map.fetch!(:external_ids)
        |> Map.merge(external_ids)

      _external_ids ->
        Map.fetch!(context, :external_ids)
    end
  end

  defp occurred_at_ms(event, context) do
    event_value(event, :occurred_at_ms) ||
      event_value(event, :timestamp_ms) ||
      Map.get(context, :occurred_at_ms, System.system_time(:millisecond))
  end

  defp progress_state(event) do
    event_value(event, :progress_state) ||
      event_value(event, :state) ||
      payload_value(event, :progress_state) ||
      payload_value(event, :state)
  end

  defp ordering_metadata(event) do
    case event_value(event, :ordering_metadata) ||
           event_value(event, :ordering) ||
           event_value(event, :order) ||
           payload_value(event, :ordering_metadata) ||
           payload_value(event, :ordering) ||
           payload_value(event, :order) do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end

  defp completion_status(event) do
    event_value(event, :status) ||
      payload_value(event, :status) ||
      cond do
        not is_nil(completion_error(event)) -> :error
        not is_nil(completion_result(event)) -> :ok
        true -> :completed
      end
  end

  defp completion_result(event) do
    event_value(event, :result) ||
      payload_value(event, :result)
  end

  defp completion_error(event) do
    event_value(event, :error) ||
      payload_value(event, :error)
  end

  defp completion_metadata(event) do
    case event_value(event, :completion_metadata) ||
           event_value(event, :completion) ||
           event_value(event, :metadata) ||
           payload_value(event, :completion_metadata) ||
           payload_value(event, :completion) ||
           payload_value(event, :metadata) do
      metadata when is_map(metadata) -> metadata
      _metadata -> %{}
    end
  end

  defp payload_value(event, key) do
    case event_value(event, :payload) do
      payload when is_map(payload) -> event_value(payload, key)
      _payload -> nil
    end
  end

  defp enrich_raw_transport_metadata(events, source_event) do
    metadata = raw_transport_metadata(source_event)

    if map_size(metadata) == 0 do
      events
    else
      Enum.map(events, &put_raw_event_metadata(&1, metadata))
    end
  end

  defp raw_transport_metadata(%{} = source_event) do
    transport = source_transport(source_event)
    keys = Map.get(@raw_metadata_keys, transport, [])

    metadata_sources =
      [
        source_event,
        Map.get(source_event, :metadata),
        Map.get(source_event, "metadata")
      ]
      |> Enum.filter(&is_map/1)

    metadata_sources
    |> unknown_raw_metadata(keys)
    |> Map.merge(known_raw_metadata(metadata_sources, keys))
  end

  defp raw_transport_metadata(_source_event), do: %{}

  defp known_raw_metadata(metadata_sources, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_metadata_value(metadata_sources, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp unknown_raw_metadata([_source_event | explicit_metadata_sources], known_keys) do
    known_key_strings = MapSet.new(known_keys, &Atom.to_string/1)
    known_keys = MapSet.new(known_keys)

    Enum.reduce(explicit_metadata_sources, %{}, fn metadata, acc ->
      metadata =
        Map.reject(metadata, fn
          {key, _value} when is_atom(key) -> MapSet.member?(known_keys, key)
          {key, _value} when is_binary(key) -> MapSet.member?(known_key_strings, key)
          {_key, _value} -> false
        end)

      Map.merge(acc, metadata)
    end)
  end

  defp unknown_raw_metadata(_metadata_sources, _known_keys), do: %{}

  defp fetch_metadata_value(metadata_sources, key) do
    string_key = Atom.to_string(key)

    Enum.find_value(metadata_sources, :error, fn metadata ->
      cond do
        Map.has_key?(metadata, key) -> {:ok, Map.fetch!(metadata, key)}
        Map.has_key?(metadata, string_key) -> {:ok, Map.fetch!(metadata, string_key)}
        true -> nil
      end
    end)
  end

  defp put_raw_event_metadata(%LifecycleEvent{raw_event: raw_event} = event, metadata)
       when is_map(raw_event) do
    %{event | raw_event: Map.merge(metadata, raw_event)}
  end

  defp put_raw_event_metadata(%{} = event, metadata) do
    case Map.get(event, :raw_event) || Map.get(event, "raw_event") do
      raw_event when is_map(raw_event) ->
        put_in_raw_event(event, Map.merge(metadata, raw_event))

      _raw_event ->
        event
    end
  end

  defp put_raw_event_metadata(event, _metadata), do: event

  defp put_in_raw_event(event, raw_event) when is_map_key(event, :raw_event) do
    Map.put(event, :raw_event, raw_event)
  end

  defp put_in_raw_event(event, raw_event), do: Map.put(event, "raw_event", raw_event)

  defp event_context(source_event, default_context, next_seq) do
    source_context = source_context(source_event)

    default_context
    |> Map.put(:event_seq, next_seq)
    |> Map.merge(source_context)
  end

  defp source_context(%{} = event) do
    event
    |> Map.get(:context, Map.get(event, "context", %{}))
    |> normalize_partial_context()
  end

  defp source_context(_event), do: %{}

  defp normalize_context(context) when is_map(context) do
    @default_context
    |> Map.merge(normalize_partial_context(context))
    |> ensure_external_ids()
  end

  defp normalize_context(_context), do: @default_context

  defp normalize_partial_context(context) when is_map(context) do
    context
    |> atomize_known_context_keys()
    |> ensure_external_ids()
  end

  defp normalize_partial_context(_context), do: %{}

  defp ensure_external_ids(%{external_ids: external_ids} = context) when is_map(external_ids),
    do: context

  defp ensure_external_ids(%{external_ids: _external_ids} = context),
    do: Map.put(context, :external_ids, %{})

  defp ensure_external_ids(context), do: context

  defp atomize_known_context_keys(context) do
    Enum.reduce(context, %{}, fn {key, value}, acc ->
      case normalize_context_key(key) do
        nil -> acc
        normalized_key -> Map.put(acc, normalized_key, value)
      end
    end)
  end

  defp normalize_context_key(key)
       when key in [
              :event_seq,
              :parent_call_id,
              :runtime_source,
              :external_ids,
              :occurred_at_ms,
              :status,
              :headers,
              :request_id,
              :method,
              :params
            ],
       do: key

  defp normalize_context_key(key) when is_binary(key) do
    Map.get(
      %{
        "event_seq" => :event_seq,
        "parent_call_id" => :parent_call_id,
        "runtime_source" => :runtime_source,
        "external_ids" => :external_ids,
        "occurred_at_ms" => :occurred_at_ms,
        "status" => :status,
        "headers" => :headers,
        "request_id" => :request_id,
        "method" => :method,
        "params" => :params
      },
      key
    )
  end

  defp normalize_context_key(_key), do: nil

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
      case {event_transports, source_transport(source_event)} do
        {[], nil} -> []
        {[], transport} -> [transport]
        {transports, _source_transport} -> transports
      end

    Enum.reduce(event_transports, transports, fn transport, acc ->
      MapSet.put(acc, normalize_transport(transport))
    end)
  end

  defp source_transport(%{} = event),
    do: normalize_transport(Map.get(event, :transport) || Map.get(event, "transport"))

  defp source_transport(_event), do: nil

  defp normalize_transport("stdio"), do: :stdio
  defp normalize_transport("sse"), do: :sse
  defp normalize_transport("streamable_http"), do: :streamable_http
  defp normalize_transport(transport), do: transport

  defp normalized_lifecycle_event?(%{} = event) do
    Map.has_key?(event, :event_seq) or Map.has_key?(event, "event_seq")
  end

  defp options_map(options) when is_list(options), do: Map.new(options)
  defp options_map(options) when is_map(options), do: options
  defp options_map(_options), do: %{}
end
