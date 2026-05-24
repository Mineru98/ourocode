defmodule Ourocode.MCP.Transport.Stdio.RawEvent do
  @moduledoc """
  Raw stdio transport metadata and canonical journal event projection.
  """

  alias Ourocode.MCP.LifecycleEvent

  @spec context(map(), :inbound | :outbound, term(), integer()) :: map()
  def context(transport_state, stream_direction, raw_payload, timestamp_ms)
      when is_map(transport_state) and is_integer(timestamp_ms) do
    %{
      transport: :stdio,
      transport_type: :stdio,
      process_identifier: process_identifier(transport_state),
      session_identifier: session_identifier(transport_state),
      stream_direction: stream_direction,
      timestamp_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref(raw_payload)
    }
  end

  @spec annotate(map(), map()) :: map()
  def annotate(raw_event, raw_context) when is_map(raw_event) and is_map(raw_context) do
    Map.merge(raw_event, raw_context)
  end

  @spec annotate_lifecycle(LifecycleEvent.t(), map()) :: LifecycleEvent.t()
  def annotate_lifecycle(%LifecycleEvent{raw_event: raw_event} = event, raw_context)
      when is_map(raw_event) and is_map(raw_context) do
    %{event | raw_event: annotate(raw_event, raw_context)}
  end

  def annotate_lifecycle(%LifecycleEvent{} = event, _raw_context), do: event

  @spec canonical_journal_event(LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(%LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> canonical_journal_event()
  end

  def canonical_journal_event(%{} = event) do
    event
    |> canonicalize_journal_notification()
    |> canonicalize_journal_decode_error()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec raw_payload_ref(binary() | term()) :: String.t()
  def raw_payload_ref(payload) when is_binary(payload) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  def raw_payload_ref(payload) do
    "sha256:" <>
      Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(payload)), case: :lower)
  end

  defp process_identifier(state) do
    %{
      port: inspect(Map.get(state, :port)),
      os_pid: port_os_pid(Map.get(state, :port))
    }
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp session_identifier(state) do
    external_ids = Map.get(state, :external_ids, %{})

    external_ids["session_id"] ||
      external_ids[:session_id] ||
      external_ids["native_session_id"] ||
      external_ids[:native_session_id] ||
      Map.get(state, :parent_call_id)
  end

  defp canonicalize_journal_notification(%{notification: notification} = event)
       when is_map(notification) do
    Map.put(
      event,
      :notification,
      Map.take(notification, ["id", "method", "params", :id, :method, :params])
    )
  end

  defp canonicalize_journal_notification(event), do: event

  defp canonicalize_journal_decode_error(
         %{type: :transport_decode_failed, error: {:malformed_stdout_line, reason}} = event
       ) do
    reason_code = decode_reason_code(reason)

    event
    |> Map.put(:error, {:malformed_stdout_line, reason_code})
    |> Map.put(:error_details, %{reason: reason_code})
  end

  defp canonicalize_journal_decode_error(event), do: event

  defp decode_reason_code({reason, _raw_fragment}), do: reason
  defp decode_reason_code([reason, _raw_fragment]), do: reason
  defp decode_reason_code(reason), do: reason
end
