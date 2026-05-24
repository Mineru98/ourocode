defmodule Ourocode.MCP.Transport.SSE.StreamProcessor do
  @moduledoc """
  Converts SSE TCP response and event-stream chunks into lifecycle events.

  The GenServer owns sockets and mailbox flow. This module owns the pure-ish
  state transition from buffered bytes to emitted transport events.
  """

  alias Ourocode.MCP.Transport.SSE.Connection
  alias Ourocode.MCP.Transport.SSE.EventEmitter
  alias Ourocode.MCP.Transport.SSE.LifecycleNormalizer
  alias Ourocode.MCP.Transport.SSE.Parser
  alias Ourocode.MCP.Transport.SSE.PendingRequest
  alias Ourocode.MCP.Transport.SSE.RawEvent

  @spec process_response_chunk(map()) :: map()
  def process_response_chunk(state) when is_map(state) do
    case Connection.parse_response_buffer(state.response_buffer) do
      {:connected, status, headers, rest} ->
        state
        |> Map.put(:status, status)
        |> Map.put(:headers, headers)
        |> Map.put(:response_buffer, "")
        |> Map.put(:sse_buffer, rest)
        |> EventEmitter.emit(:transport_connected, %{})
        |> process_sse_chunk()

      {:http_error, status, headers} ->
        state
        |> Map.put(:status, status)
        |> Map.put(:headers, headers)
        |> Map.put(:response_buffer, "")
        |> EventEmitter.emit(:transport_failed, %{error: {:http_error, status}})

      {:error, reason} ->
        EventEmitter.emit(state, :transport_failed, %{error: reason})

      :partial ->
        state
    end
  end

  @spec process_sse_chunk(map()) :: map()
  def process_sse_chunk(state) when is_map(state) do
    {frames, rest} = Parser.split_complete_frames(state.sse_buffer)

    state
    |> Map.put(:sse_buffer, rest)
    |> then(fn next_state -> Enum.reduce(frames, next_state, &handle_sse_frame/2) end)
  end

  defp handle_sse_frame(frame, state) do
    raw_context = RawEvent.context(state, frame)

    case Parser.parse_frame(frame) do
      {:ok, nil} ->
        state

      {:ok, event} ->
        emit_json_rpc_event(state, annotate_raw_event(event, raw_context))

      {:error, reason} ->
        EventEmitter.emit(state, :transport_decode_failed, %{
          error: reason,
          raw_event: annotate_raw_event(%{frame: frame}, raw_context)
        })
    end
  end

  defp emit_json_rpc_event(state, %{"data" => %{"id" => request_id, "result" => result}} = event) do
    complete_parent_call(state, to_string(request_id), {:ok, result}, event)
  end

  defp emit_json_rpc_event(state, %{"data" => %{"id" => request_id, "error" => error}} = event) do
    complete_parent_call(state, to_string(request_id), {:error, error}, event)
  end

  defp emit_json_rpc_event(state, %{"data" => %{"method" => _method}} = event) do
    emit_normalized_event(state, event)
  end

  defp emit_json_rpc_event(state, %{"data" => _decoded} = event) do
    emit_normalized_event(state, event)
  end

  defp emit_json_rpc_event(state, %{"metadata" => _metadata} = event) do
    emit_normalized_event(state, event)
  end

  defp emit_normalized_event(state, event) do
    EventEmitter.emit_normalized(
      state,
      LifecycleNormalizer.normalize_parsed_event(event, EventEmitter.context(state))
    )
  end

  defp complete_parent_call(state, request_id, reply, sse_event) do
    {pending, state} = PendingRequest.pop(state, request_id)

    if pending do
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, reply)
    end

    context =
      state
      |> EventEmitter.context()
      |> Map.merge(PendingRequest.context_attrs(pending))

    state
    |> EventEmitter.emit_normalized(
      LifecycleNormalizer.normalize_parsed_event(sse_event, context)
    )
  end

  defp annotate_raw_event(%{} = raw_event, raw_context) when is_map(raw_context) do
    RawEvent.build_record(raw_event, raw_context)
  end
end
