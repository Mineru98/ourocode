defmodule Ourocode.Dashboard.ParentMcpPaneLifecycle do
  @moduledoc """
  Applies parent MCP lifecycle and cleanup events to pane state.
  """

  alias Ourocode.Dashboard.ParentMcpPaneEvent

  @spec apply_event(map(), map()) :: map()
  def apply_event(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        event
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(event) do
    case ParentMcpPaneEvent.from_cleanup_event(event) do
      {:ok, cleanup} ->
        apply_cleanup_event(state, cleanup)

      :ignore ->
        apply_lifecycle_event(state, event, focused)
    end
  end

  defp apply_lifecycle_event(
         %{working: working, completed: completed, open: open} = state,
         event,
         focused
       ) do
    case ParentMcpPaneEvent.from_lifecycle_event(event) do
      {:ok, pane} ->
        pane_id = pane.id

        {working, completed} =
          if ParentMcpPaneEvent.terminal?(event) do
            completed_pane = merge_existing(working ++ completed, pane)

            {
              reject_pane(working, pane_id),
              upsert_pane(completed, completed_pane)
            }
          else
            {
              upsert_pane(working, pane),
              reject_pane(completed, pane_id)
            }
          end

        %{
          state
          | working: working,
            completed: completed,
            focused: focused || pane_id,
            open: append_once(open, pane_id)
        }

      :ignore ->
        state
    end
  end

  defp merge_existing(panes, pane) do
    case Enum.find(panes, &(&1.id == pane.id)) do
      nil -> pane
      existing -> merge_pane(existing, pane)
    end
  end

  defp upsert_pane([], pane), do: [pane]

  defp upsert_pane([%{id: id} = existing | rest], %{id: id} = pane) do
    [merge_pane(existing, pane) | rest]
  end

  defp upsert_pane([existing | rest], pane), do: [existing | upsert_pane(rest, pane)]

  defp merge_pane(existing, pane) do
    event_count = get_in(existing, [:pane_state, :event_count]) || 0
    notification_count = get_in(existing, [:pane_state, :notification_count]) || 0

    existing
    |> Map.merge(pane, fn _key, old, new -> new || old end)
    |> Map.put(:created_at_ms, existing.created_at_ms)
    |> Map.put(:external_ids, Map.merge(existing.external_ids, pane.external_ids))
    |> Map.put(
      :pane_state,
      existing.pane_state
      |> Map.merge(pane.pane_state)
      |> Map.put(:event_count, event_count + 1)
      |> Map.put(:notification_count, notification_count + pane.pane_state.notification_count)
    )
  end

  defp reject_pane(panes, pane_id), do: Enum.reject(panes, &(&1.id == pane_id))

  defp apply_cleanup_event(state, %{parent_call_id: parent_call_id}) do
    pane_id = pane_id(parent_call_id)

    remove_panes(state, fn pane -> pane.parent_call_id == parent_call_id or pane.id == pane_id end)
  end

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
    end
  end

  defp append_once(values, value) do
    if value in values do
      values
    else
      values ++ [value]
    end
  end

  defp pane_id(parent_call_id), do: "parent-mcp:" <> parent_call_id
end
