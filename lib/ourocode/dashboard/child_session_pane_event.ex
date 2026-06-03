defmodule Ourocode.Dashboard.ChildSessionPaneEvent do
  @moduledoc """
  Converts MCP and journal lifecycle events into child session pane maps.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.Dashboard.ChildSessionPaneRuntimeIdentity
  alias Ourocode.Dashboard.ChildSessionStream

  @spec from_lifecycle_event(map()) :: {:ok, map()} | :ignore
  def from_lifecycle_event(event) when is_map(event) do
    with {:ok, {child_id, child_id_source}} <- ChildSessionPaneRuntimeIdentity.extract(event),
         {:ok, parent_call_id} <- required_string(event, :parent_call_id),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, transport} <- required_transport(event),
         true <- child_pane_event?(event) do
      event_seq = Map.get(event, :event_seq, 0)
      occurred_at_ms = Map.get(event, :occurred_at_ms, System.system_time(:millisecond))

      {:ok,
       %{
         id: pane_id(child_id),
         kind: :child_session,
         status: status_for(event),
         child_id: child_id,
         parent_call_id: parent_call_id,
         runtime_source: runtime_source,
         transport: transport,
         external_ids:
           ChildSessionPaneRuntimeIdentity.external_ids(event, child_id, child_id_source),
         stream_cursor: ChildSessionStream.stream_cursor(event, transport, event_seq, child_id),
         pane_state: %{
           open?: true,
           focused?: false,
           renderer: :default_child_session,
           last_event_seq: event_seq,
           stream_entries:
             ChildSessionStream.stream_entries_for_event(event, event_seq, occurred_at_ms)
         },
         created_at_ms: occurred_at_ms,
         updated_at_ms: occurred_at_ms
       }}
    else
      _error -> :ignore
    end
  end

  def from_lifecycle_event(_event), do: :ignore

  @spec from_pane_lifecycle_event(map()) :: {:ok, map(), atom()} | :ignore
  def from_pane_lifecycle_event(event) when is_map(event) do
    with {:ok, lifecycle_type} <- ChildSessionMetadata.lifecycle_type(event),
         {:ok, child_id} <- ChildSessionMetadata.string(event, :child_id),
         {:ok, pane_id} <- ChildSessionMetadata.string_any(event, [:pane_id, :id]),
         {:ok, parent_call_id} <- ChildSessionMetadata.string(event, :parent_call_id),
         {:ok, runtime_source} <- ChildSessionMetadata.string(event, :runtime_source),
         {:ok, transport} <- ChildSessionMetadata.transport(event) do
      now =
        ChildSessionMetadata.integer(event, :updated_at_ms) ||
          ChildSessionMetadata.integer(event, :occurred_at_ms) ||
          System.system_time(:millisecond)

      created_at_ms = ChildSessionMetadata.integer(event, :created_at_ms) || now

      external_ids =
        event
        |> ChildSessionMetadata.map_value(:external_ids, %{})
        |> Map.put_new("childID", child_id)

      {:ok,
       %{
         id: pane_id,
         kind: :child_session,
         status: ChildSessionMetadata.status(event, lifecycle_type),
         child_id: child_id,
         parent_call_id: parent_call_id,
         runtime_source: runtime_source,
         transport: transport,
         external_ids: external_ids,
         stream_cursor:
           event
           |> ChildSessionMetadata.map_value(:stream_cursor, %{})
           |> Map.merge(%{
             transport: transport,
             child_id: child_id
           }),
         pane_state:
           %{
             open?: true,
             focused?: false,
             renderer: :default_child_session,
             last_acknowledged_stream_cursor:
               ChildSessionMetadata.acknowledged_stream_cursor(event)
           }
           |> Map.merge(ChildSessionMetadata.pane_projection_state(event)),
         created_at_ms: created_at_ms,
         updated_at_ms: now
       }, lifecycle_type}
    else
      _error -> :ignore
    end
  end

  def from_pane_lifecycle_event(_event), do: :ignore

  @spec from_stdio_event(map()) :: {:ok, map()} | :ignore
  def from_stdio_event(%{transport: :stdio} = event), do: from_lifecycle_event(event)
  def from_stdio_event(_event), do: :ignore

  @spec stabilize_fallback_child_id([map()], map()) :: map()
  def stabilize_fallback_child_id(existing_panes, pane),
    do: ChildSessionPaneRuntimeIdentity.stabilize_fallback_child_id(existing_panes, pane)

  @spec fallback_pane?(map()) :: boolean()
  def fallback_pane?(pane), do: ChildSessionPaneRuntimeIdentity.fallback_pane?(pane)

  defp required_string(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp required_transport(%{transport: transport})
       when transport in [:stdio, :streamable_http, :sse],
       do: {:ok, transport}

  defp required_transport(_event), do: :error

  defp child_pane_event?(event) do
    Map.get(event, :type) in [:parent_call_started, :parent_call_event, :parent_call_result]
  end

  defp status_for(%{type: :parent_call_result} = event) do
    if completed_result?(event), do: :completed, else: :working
  end

  defp status_for(_event), do: :working

  defp completed_result?(event) do
    event
    |> completion_candidates()
    |> Enum.any?(&completed_status?/1)
  end

  defp completion_candidates(event) do
    [
      Map.get(event, :status),
      Map.get(event, "status"),
      get_in(event, [:result, "status"]),
      get_in(event, [:result, :status]),
      get_in(event, [:raw_event, "result", "status"]),
      get_in(event, [:raw_event, :result, :status]),
      get_in(event, [:raw_event, "data", "result", "status"]),
      get_in(event, [:raw_event, :data, :result, :status])
    ]
  end

  defp completed_status?(status) when status in [:completed, :complete, :done], do: true

  defp completed_status?(status) when is_binary(status) do
    status
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["completed", "complete", "done", "succeeded", "success"]))
  end

  defp completed_status?(_status), do: false

  defp pane_id(child_id), do: ChildSessionIdentity.pane_id(child_id)
end
