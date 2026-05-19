defmodule Ourocode.MCP.Transport.StreamableHTTP.FrameNormalizer do
  @moduledoc """
  Normalizes raw streamable HTTP frames into journal-ready lifecycle events.

  The streamable HTTP transport can receive either plain JSON-RPC response
  bodies or `text/event-stream` frames. This module is the public raw-frame
  boundary: bytes are decoded once, then converted into the same
  `Ourocode.MCP.LifecycleEvent` shape used by the rest of the runtime.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer
  alias Ourocode.MCP.Transport.StreamableHTTP.Parser

  @type context :: LifecycleNormalizer.context()

  @doc """
  Converts one representative raw HTTP stream frame into canonical events.

  Supported frame variants:

    * complete `text/event-stream` frames carrying JSON-RPC notifications
    * complete `text/event-stream` frames carrying JSON-RPC responses/errors
    * SSE metadata frames such as `retry:`
    * plain JSON-RPC HTTP response bodies

  Malformed frames return a streamable HTTP `:transport_decode_failed`
  lifecycle event instead of being dropped.
  """
  @spec normalize_raw_frame(String.t(), context()) :: {:ok, [LifecycleEvent.t()]}
  def normalize_raw_frame(frame, context) when is_binary(frame) and is_map(context) do
    cond do
      sse_frame?(frame) ->
        normalize_sse_frame(frame, context)

      true ->
        normalize_json_frame(frame, context)
    end
  end

  defp normalize_sse_frame(frame, context) do
    case Parser.parse_complete_events(ensure_complete_sse_frame(frame)) do
      {:ok, [], ""} ->
        {:ok, []}

      {:ok, parsed_events, ""} ->
        with {:ok, events} <- normalize_parsed_events(parsed_events, context) do
          {:ok, Enum.map(events, &annotate_raw_response_event(&1, frame, context))}
        end

      {:ok, _events, rest} ->
        {:ok, [decode_failed(context, {:incomplete_sse_frame, rest}, frame)]}

      {:error, reason} ->
        {:ok, [decode_failed(context, reason, frame)]}
    end
  end

  defp normalize_json_frame(frame, context) do
    headers = Map.get(context, :headers, [{"content-type", "application/json"}])
    status = Map.get(context, :status, 200)

    case Json.decode(frame) do
      {:ok, _decoded} ->
        with {:ok, events} <- LifecycleNormalizer.normalize_body(status, headers, frame, context) do
          {:ok, Enum.map(events, &annotate_raw_response_event(&1, frame, context))}
        end

      {:error, reason} ->
        {:ok, [decode_failed(context, reason, frame)]}
    end
  end

  defp normalize_parsed_events(parsed_events, context) do
    parsed_events
    |> Enum.with_index()
    |> Enum.reduce({:ok, []}, fn {parsed_event, index}, {:ok, events} ->
      event_context = Map.put(context, :event_seq, Map.fetch!(context, :event_seq) + index)

      case normalize_parsed_event(parsed_event, event_context) do
        {:ok, next_events} ->
          {:ok, events ++ Enum.map(next_events, &preserve_sse_metadata(&1, parsed_event))}
      end
    end)
  end

  defp preserve_sse_metadata(%LifecycleEvent{} = event, %{} = parsed_event) do
    raw_event =
      case event.raw_event do
        raw_event when is_map(raw_event) -> Map.merge(raw_event, parsed_event)
        _raw_event -> parsed_event
      end

    %{event | raw_event: raw_event}
  end

  defp normalize_parsed_event(%{"data" => _data} = parsed_event, context) do
    LifecycleNormalizer.normalize_sse_events([parsed_event], context)
  end

  defp normalize_parsed_event(%{"metadata" => metadata} = parsed_event, context) do
    {:ok,
     [
       build(:transport_metadata, context, %{
         payload: metadata,
         raw_event: parsed_event
       })
     ]}
  end

  defp normalize_parsed_event(parsed_event, context) do
    {:ok, [decode_failed(context, :missing_data_or_metadata, parsed_event)]}
  end

  defp sse_frame?(frame) do
    frame
    |> String.trim_leading()
    |> String.starts_with?(["event:", "data:", "id:", "retry:", ":"])
  end

  defp ensure_complete_sse_frame(frame) do
    if Regex.match?(~r/\r?\n\r?\n\z/, frame), do: frame, else: frame <> "\n\n"
  end

  defp decode_failed(context, reason, raw_frame) do
    build(:transport_decode_failed, context, %{
      error: reason,
      error_details: %{reason: reason},
      raw_event:
        StreamableHTTP.build_raw_response_event_record(
          [
            status: Map.get(context, :status),
            headers: Map.get(context, :headers),
            raw_payload: raw_frame
          ],
          %{"raw_frame" => raw_frame},
          context
        )
    })
  end

  defp annotate_raw_response_event(%LifecycleEvent{} = event, raw_payload, context) do
    response_record =
      StreamableHTTP.build_raw_response_event_record(
        [
          status: Map.get(context, :status),
          headers: Map.get(context, :headers),
          raw_payload: raw_payload
        ],
        event.raw_event || %{},
        Map.put(context, :request_id, event.request_id || Map.get(context, :request_id))
      )

    %{event | raw_event: response_record}
  end

  defp build(type, context, attrs) do
    LifecycleEvent.new(
      type,
      Map.merge(
        %{
          event_seq: Map.fetch!(context, :event_seq),
          transport: :streamable_http,
          parent_call_id: Map.fetch!(context, :parent_call_id),
          runtime_source: Map.fetch!(context, :runtime_source),
          external_ids: Map.fetch!(context, :external_ids),
          occurred_at_ms: Map.get(context, :occurred_at_ms, System.system_time(:millisecond)),
          status: Map.get(context, :status),
          headers: Map.get(context, :headers)
        },
        attrs
      )
    )
  end
end
