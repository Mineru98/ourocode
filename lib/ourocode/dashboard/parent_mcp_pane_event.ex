defmodule Ourocode.Dashboard.ParentMcpPaneEvent do
  @moduledoc """
  Converts parent MCP lifecycle and cleanup events into pane projection inputs.
  """

  @terminal_types MapSet.new([
                    :parent_call_result,
                    :parent_call_failed,
                    :parent_call_write_failed,
                    :parent_call_unmatched_result,
                    :transport_decode_failed,
                    :transport_exited
                  ])

  @doc """
  Builds a parent MCP pane projection from a normalized lifecycle event.
  """
  @spec from_lifecycle_event(map()) :: {:ok, map()} | :ignore
  def from_lifecycle_event(event) when is_map(event) do
    with true <- parent_lifecycle_event?(event),
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, transport} <- required_atom(event, :transport) do
      event_seq = integer_value(event, :event_seq, 0)
      occurred_at_ms = integer_value(event, :occurred_at_ms, System.system_time(:millisecond))
      type = Map.get(event, :type)

      {:ok,
       %{
         id: pane_id(parent_call_id),
         kind: :parent_mcp_call,
         status: status_for(type),
         parent_call_id: parent_call_id,
         runtime_source: runtime_source,
         transport: transport,
         external_ids: external_ids_map(event),
         request_id: string_value(event, :request_id, nil),
         method: string_value(event, :method, nil),
         params: Map.get(event, :params),
         result: Map.get(event, :result),
         error: Map.get(event, :error),
         notification: Map.get(event, :notification),
         stream_cursor: %{
           transport: transport,
           parent_call_id: parent_call_id,
           event_seq: event_seq
         },
         pane_state: %{
           open?: true,
           focused?: false,
           renderer: :default_parent_mcp,
           lifecycle_type: type,
           last_event_seq: event_seq,
           event_count: 1,
           notification_count: notification_count(event)
         },
         created_at_ms: occurred_at_ms,
         updated_at_ms: occurred_at_ms
       }}
    else
      _ -> :ignore
    end
  end

  def from_lifecycle_event(_event), do: :ignore

  @doc """
  Builds a local parent pane cleanup instruction from supervised stream cleanup.
  """
  @spec from_cleanup_event(map()) :: {:ok, map()} | :ignore
  def from_cleanup_event(%{cleanup_reason: cleanup_reason, stream_kind: stream_kind} = event)
      when cleanup_reason in [:idle_timeout, :operation_timeout] and
             stream_kind in [:child, :session, :transport] do
    case cleanup_parent_call_id(event) do
      {:ok, parent_call_id} -> {:ok, %{parent_call_id: parent_call_id}}
      :error -> :ignore
    end
  end

  def from_cleanup_event(%{lifecycle_type: :stream_terminated} = event) do
    from_cleanup_event(Map.delete(event, :lifecycle_type))
  end

  def from_cleanup_event(_event), do: :ignore

  @doc """
  Returns true when a lifecycle event represents a terminal parent MCP state.
  """
  @spec terminal?(map()) :: boolean()
  def terminal?(event), do: MapSet.member?(@terminal_types, Map.get(event, :type))

  defp parent_lifecycle_event?(event) do
    case Map.get(event, :type) do
      :parent_call_started -> true
      :parent_call_event -> true
      :parent_call_result -> true
      :parent_call_failed -> true
      :parent_call_write_failed -> true
      :parent_call_unmatched_result -> true
      :transport_decode_failed -> true
      :transport_exited -> true
      _ -> false
    end
  end

  defp status_for(:parent_call_started), do: :starting
  defp status_for(:parent_call_event), do: :streaming
  defp status_for(:parent_call_result), do: :completed
  defp status_for(:parent_call_unmatched_result), do: :completed
  defp status_for(_failed_or_exit), do: :failed

  defp pane_id(parent_call_id), do: "parent-mcp:" <> parent_call_id

  defp notification_count(%{type: :parent_call_event}), do: 1
  defp notification_count(_event), do: 0

  defp external_ids_map(event) do
    case Map.get(event, :external_ids) do
      external_ids when is_map(external_ids) -> external_ids
      _ -> %{}
    end
  end

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp required_atom(event, key) do
    case Map.get(event, key) do
      value when is_atom(value) -> {:ok, value}
      _ -> :error
    end
  end

  defp string_value(map, key, default) do
    case Map.get(map, key) do
      nil -> default
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp integer_value(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> default
        end

      _ ->
        default
    end
  end

  defp cleanup_parent_call_id(event) do
    case cleanup_identifier(event, [
           :parent_call_id,
           :parentCallID,
           "parent_call_id",
           "parentCallID"
         ]) do
      nil -> :error
      parent_call_id -> {:ok, parent_call_id}
    end
  end

  defp cleanup_identifier(event, keys) when is_map(event) do
    keys
    |> Enum.find_value(fn key -> normalize_runtime_id(Map.get(event, key)) end)
  end

  defp cleanup_identifier(_event, _keys), do: nil

  defp normalize_runtime_id(value) when is_binary(value) and value != "", do: value
  defp normalize_runtime_id(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_runtime_id(_value), do: nil
end
