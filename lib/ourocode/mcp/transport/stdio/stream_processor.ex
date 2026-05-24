defmodule Ourocode.MCP.Transport.Stdio.StreamProcessor do
  @moduledoc """
  Converts stdio stdout lines into lifecycle events and pending-call replies.

  The transport GenServer owns the port and timeout mailbox. This module owns
  parsing one stdout line and routing the resulting protocol message.
  """

  alias Ourocode.MCP.RuntimeEventParser
  alias Ourocode.MCP.Transport.Stdio.EventEmitter
  alias Ourocode.MCP.Transport.Stdio.LifecycleNormalizer
  alias Ourocode.MCP.Transport.Stdio.PendingRequest
  alias Ourocode.MCP.Transport.Stdio.RawEvent
  alias Ourocode.MCP.Transport.StdoutJsonlParser

  @spec handle_line(map(), binary()) :: map()
  def handle_line(state, line) when is_map(state) and is_binary(line) do
    raw_context = raw_event_context(state, :inbound, String.trim(line))

    case StdoutJsonlParser.parse_protocol_line_detailed(line, state.codec) do
      {:ok, raw_message} ->
        route_raw_protocol_message(state, raw_message, raw_context)

      {:error, %{line: malformed_line, reason: reason}} ->
        EventEmitter.emit(state, :transport_decode_failed, %{
          error: {:malformed_stdout_line, reason},
          error_details: %{reason: reason},
          raw_event: RawEvent.annotate(%{line: malformed_line}, raw_context)
        })

      :ignore ->
        state
    end
  end

  defp route_raw_protocol_message(state, %{kind: kind} = raw_message, raw_context)
       when kind in [:request, :notification, :unknown] do
    EventEmitter.emit_normalized(
      state,
      raw_message
      |> LifecycleNormalizer.normalize_protocol_message(EventEmitter.context(state))
      |> RawEvent.annotate_lifecycle(raw_context)
    )
  end

  defp route_raw_protocol_message(state, %{kind: kind, raw: decoded, id: request_id}, raw_context)
       when kind in [:response, :error_response] do
    complete_request(state, to_string(request_id), decoded, raw_context)
  end

  defp complete_request(state, request_id, decoded, raw_context) do
    case PendingRequest.pop(state, request_id) do
      {nil, state} ->
        EventEmitter.emit(state, :parent_call_unmatched_result, %{
          external_ids: event_external_ids(state, decoded),
          request_id: request_id,
          result: decoded,
          raw_event: RawEvent.annotate(decoded, raw_context)
        })

      {pending, state} ->
        Process.cancel_timer(pending.timer)
        reply = PendingRequest.reply_from_decoded(decoded)

        GenServer.reply(pending.from, reply)

        response_context =
          state
          |> EventEmitter.context()
          |> Map.put(:external_ids, event_external_ids(state, decoded, pending.external_ids))

        state
        |> EventEmitter.emit_normalized(
          LifecycleNormalizer.parent_call_response(
            decoded,
            reply,
            response_context,
            PendingRequest.response_attrs(request_id, pending)
          )
          |> RawEvent.annotate_lifecycle(raw_context)
        )
    end
  end

  defp event_external_ids(state, payload) do
    Map.merge(state.external_ids, RuntimeEventParser.extract_external_ids(payload))
  end

  defp event_external_ids(state, payload, inherited_external_ids) do
    state.external_ids
    |> Map.merge(inherited_external_ids || %{})
    |> Map.merge(RuntimeEventParser.extract_external_ids(payload))
  end

  defp raw_event_context(state, stream_direction, raw_payload) do
    RawEvent.context(state, stream_direction, raw_payload, System.system_time(:millisecond))
  end
end
