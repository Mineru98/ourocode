defmodule Ourocode.Dashboard.ChildSessionPaneEventRouter do
  @moduledoc """
  Routes child-session lifecycle, cleanup, and replay events into pane state.
  """

  alias Ourocode.Dashboard.ChildSessionCleanup
  alias Ourocode.Dashboard.ChildSessionPaneEvent
  alias Ourocode.Dashboard.ChildSessionPaneLifecycle
  alias Ourocode.Dashboard.ChildSessionRelationshipRecovery
  alias Ourocode.Journal.RelationshipRecoveryIndex

  @spec recover_from_journal([map()], map()) :: map()
  def recover_from_journal(events, initial_state)
      when is_list(events) and is_map(initial_state) do
    Enum.reduce(events, initial_state, &apply_event(&2, &1))
  end

  @spec restore_recovered_relationships(map(), RelationshipRecoveryIndex.t()) ::
          {:ok, map()} | {:error, :invalid_relationship_recovery_index}
  def restore_recovered_relationships(
        %{working: working, completed: completed, open: open} = state,
        %RelationshipRecoveryIndex{relationships: relationships}
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_list(relationships) do
    relationships
    |> Enum.sort_by(& &1.first_event_seq)
    |> Enum.reduce_while({:ok, state}, fn relationship, {:ok, state} ->
      case restore_relationship(state, relationship) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def restore_recovered_relationships(_state, _index),
    do: {:error, :invalid_relationship_recovery_index}

  @spec apply_event(map(), map()) :: map()
  def apply_event(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        event
      )
      when is_list(working) and is_list(completed) and is_list(open) do
    case ChildSessionCleanup.from_event(event) do
      {:ok, cleanup} ->
        ChildSessionCleanup.apply(state, cleanup)

      :ignore ->
        apply_non_cleanup_event(state, event, focused)
    end
  end

  defp apply_non_cleanup_event(state, event, focused) do
    case ChildSessionPaneEvent.from_pane_lifecycle_event(event) do
      {:ok, pane, lifecycle_type} ->
        ChildSessionPaneLifecycle.apply_persisted(state, pane, lifecycle_type)

      :ignore ->
        apply_runtime_lifecycle_event(state, event, focused)
    end
  end

  defp apply_runtime_lifecycle_event(
         %{working: _working, completed: _completed, open: _open} = state,
         event,
         focused
       ) do
    case ChildSessionPaneEvent.from_lifecycle_event(event) do
      {:ok, pane} ->
        ChildSessionPaneLifecycle.apply_runtime(state, pane, focused)

      :ignore ->
        state
    end
  end

  defp restore_relationship(state, relationship) when is_map(relationship) do
    with {:ok, state, event} <-
           ChildSessionRelationshipRecovery.prepare_event(state, relationship) do
      {:ok, apply_event(state, event)}
    end
  end

  defp restore_relationship(_state, _relationship),
    do: {:error, :invalid_relationship_recovery_index}
end
