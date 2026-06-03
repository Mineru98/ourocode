defmodule Ourocode.Dashboard.ChildSessionPaneLifecycle do
  @moduledoc """
  Applies runtime and persisted child-session lifecycle panes to pane state.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.Dashboard.ChildSessionPaneEvent
  alias Ourocode.Dashboard.ChildSessionPaneLookup
  alias Ourocode.Dashboard.ChildSessionPaneState
  alias Ourocode.Dashboard.ChildSessionPaneStore
  alias Ourocode.Dashboard.ChildSessionReplay

  @spec apply_runtime(map(), map(), String.t() | nil) :: map()
  def apply_runtime(
        %{working: working, completed: completed, open: open} = state,
        pane,
        focused
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(pane) do
    existing_panes = working ++ completed
    pane = ChildSessionPaneEvent.stabilize_fallback_child_id(existing_panes, pane)
    reusable_pane = reusable_session_pane_for_event(existing_panes, pane)

    registry =
      state
      |> ChildSessionPaneState.registry()
      |> register_child_id(pane.child_id, reusable_pane)

    pane = %{pane | id: Map.fetch!(registry, pane.child_id)}
    pane_id = pane.id
    existing_pane = Enum.find(existing_panes, &(&1.id == pane_id))

    if ChildSessionReplay.replayed_at_or_before_acknowledged_cursor?(pane, existing_pane) do
      Map.put(state, :child_pane_registry, registry)
    else
      pane = ChildSessionReplay.surface_replay_cursor_gap(pane, existing_pane, pane_id)
      pane_for_insert = ChildSessionPaneStore.merge_existing(existing_panes, pane)

      {working, completed} =
        if pane.status == :completed do
          {
            ChildSessionPaneStore.reject(working, pane_id),
            ChildSessionPaneStore.upsert(
              completed,
              %{pane_for_insert | status: :completed},
              fn existing ->
                %{ChildSessionPaneStore.merge(existing, pane) | status: :completed}
              end
            )
          }
        else
          {
            ChildSessionPaneStore.upsert(working, pane_for_insert, fn existing ->
              ChildSessionPaneStore.merge(existing, pane)
            end),
            ChildSessionPaneStore.reject(completed, pane_id)
          }
        end

      %{
        state
        | working: working,
          completed: completed,
          focused: focused || pane_id,
          open: ChildSessionPaneStore.append_once(open, pane_id)
      }
      |> Map.put(:child_pane_registry, registry)
    end
  end

  @spec apply_persisted(map(), map(), atom()) :: map()
  def apply_persisted(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        pane,
        lifecycle_type
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(pane) and
             is_atom(lifecycle_type) do
    child_id = ChildSessionIdentity.registry_child_id(pane.child_id)

    registry =
      state
      |> ChildSessionPaneState.registry()
      |> register_child_id(child_id, pane)

    pane_id = Map.fetch!(registry, child_id)
    pane = %{pane | id: pane_id, child_id: child_id}
    pane_for_insert = ChildSessionPaneStore.merge_existing(working ++ completed, pane)

    {working, completed} =
      if pane.status == :completed or lifecycle_type == :child_pane_completed do
        {
          ChildSessionPaneStore.reject(working, pane_id),
          ChildSessionPaneStore.upsert(
            completed,
            %{pane_for_insert | status: :completed},
            fn existing ->
              %{ChildSessionPaneStore.merge(existing, pane) | status: :completed}
            end
          )
        }
      else
        {
          ChildSessionPaneStore.upsert(working, pane_for_insert, fn existing ->
            ChildSessionPaneStore.merge(existing, pane)
          end),
          ChildSessionPaneStore.reject(completed, pane_id)
        }
      end

    focused =
      cond do
        lifecycle_type == :child_pane_focused -> pane_id
        get_in(pane, [:pane_state, :focused?]) == true -> pane_id
        is_nil(focused) or focused == "" -> pane_id
        true -> focused
      end

    %{
      state
      | working: ChildSessionPaneStore.mark_focused(working, focused),
        completed: ChildSessionPaneStore.mark_focused(completed, focused),
        focused: focused,
        open: ChildSessionPaneStore.append_once(open, pane_id)
    }
    |> Map.put(:child_pane_registry, registry)
  end

  defp register_child_id(registry, child_id, %{id: pane_id})
       when is_map(registry) and is_binary(child_id) and is_binary(pane_id) do
    ChildSessionIdentity.register_child_id(registry, child_id, %{id: pane_id})
  end

  defp register_child_id(registry, child_id, _reusable_pane),
    do: ChildSessionIdentity.register_child_id(registry, child_id)

  defp reusable_session_pane_for_event(panes, pane) when is_map(pane) do
    if ChildSessionPaneEvent.fallback_pane?(pane) or explicit_child_runtime_id?(pane) do
      nil
    else
      ChildSessionPaneLookup.reusable_session_pane(panes, pane.external_ids)
    end
  end

  defp reusable_session_pane_for_event(_panes, _pane), do: nil

  defp explicit_child_runtime_id?(%{child_id: child_id, external_ids: external_ids})
       when is_binary(child_id) and is_map(external_ids) do
    ChildSessionMetadata.present_runtime_id(external_ids, "childID") == child_id or
      ChildSessionMetadata.present_runtime_id(external_ids, :childID) == child_id or
      ChildSessionMetadata.present_runtime_id(external_ids, "child_id") == child_id or
      ChildSessionMetadata.present_runtime_id(external_ids, :child_id) == child_id
  end

  defp explicit_child_runtime_id?(_pane), do: false
end
