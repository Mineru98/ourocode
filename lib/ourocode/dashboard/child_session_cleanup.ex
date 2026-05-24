defmodule Ourocode.Dashboard.ChildSessionCleanup do
  @moduledoc """
  Parses and applies child-session stream cleanup events to dashboard pane state.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.Dashboard.ChildSessionPaneState

  @timeout_reasons [:idle_timeout, :operation_timeout]

  @spec from_event(map()) :: {:ok, map()} | :ignore
  def from_event(%{cleanup_reason: cleanup_reason, stream_kind: :child} = event)
      when cleanup_reason in @timeout_reasons do
    with {:ok, child_id} <- child_id(event) do
      {:ok, %{kind: :child, child_id: child_id}}
    end
  end

  def from_event(%{cleanup_reason: cleanup_reason, stream_kind: :session} = event)
      when cleanup_reason in @timeout_reasons do
    with {:ok, session_id} <- session_id(event) do
      {:ok, %{kind: :session, session_id: session_id}}
    end
  end

  def from_event(%{lifecycle_type: :stream_terminated} = event) do
    from_event(Map.delete(event, :lifecycle_type))
  end

  def from_event(_event), do: :ignore

  @spec apply(map(), map()) :: map()
  def apply(state, %{kind: :child, child_id: child_id}) when is_map(state) do
    pane_id = ChildSessionIdentity.child_pane_key(ChildSessionPaneState.registry(state), child_id)
    remove_panes(state, fn pane -> pane.child_id == child_id or pane.id == pane_id end)
  end

  def apply(state, %{kind: :session, session_id: session_id}) when is_map(state) do
    remove_panes(state, fn pane -> pane_session_id(pane) == session_id end)
  end

  def apply(state, _cleanup), do: state

  defp remove_panes(
         %{working: working, completed: completed, open: open, focused: focused} = state,
         predicate
       ) do
    {removed_working, remaining_working} = Enum.split_with(working, predicate)
    {removed_completed, remaining_completed} = Enum.split_with(completed, predicate)

    removed_ids =
      (removed_working ++ removed_completed)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    if MapSet.size(removed_ids) == 0 do
      state
    else
      remaining_open = Enum.reject(open, &MapSet.member?(removed_ids, &1))
      focused = if MapSet.member?(removed_ids, focused), do: nil, else: focused

      %{
        state
        | working: remaining_working,
          completed: remaining_completed,
          open: remaining_open,
          focused: focused
      }
      |> Map.put(
        :child_pane_registry,
        prune_registry(ChildSessionPaneState.registry(state), removed_ids)
      )
    end
  end

  defp prune_registry(registry, removed_ids) do
    registry
    |> Enum.reject(fn {_child_id, pane_id} -> MapSet.member?(removed_ids, pane_id) end)
    |> Map.new()
  end

  defp pane_session_id(%{external_ids: external_ids}) when is_map(external_ids) do
    ChildSessionMetadata.present_runtime_id(external_ids, :session_id) ||
      ChildSessionMetadata.present_runtime_id(external_ids, "session_id") ||
      ChildSessionMetadata.present_runtime_id(external_ids, :sessionID) ||
      ChildSessionMetadata.present_runtime_id(external_ids, "sessionID") ||
      ChildSessionMetadata.present_runtime_id(external_ids, :sessionId) ||
      ChildSessionMetadata.present_runtime_id(external_ids, "sessionId")
  end

  defp pane_session_id(_pane), do: nil

  defp child_id(event) do
    case identifier(event, [
           :child_id,
           :childID,
           :childId,
           "child_id",
           "childID",
           "childId"
         ]) do
      nil -> :error
      child_id -> {:ok, child_id}
    end
  end

  defp session_id(event) do
    session_id =
      case identifier(event, [
             :session_id,
             :sessionID,
             :sessionId,
             "session_id",
             "sessionID",
             "sessionId"
           ]) do
        nil -> identifier(Map.get(event, :external_ids, %{}), [:session_id, "session_id"])
        session_id -> session_id
      end

    case session_id do
      nil -> :error
      session_id -> {:ok, session_id}
    end
  end

  defp identifier(event, keys) when is_map(event) do
    Enum.find_value(keys, fn key ->
      ChildSessionMetadata.normalize_runtime_id(Map.get(event, key))
    end)
  end

  defp identifier(_event, _keys), do: nil
end
