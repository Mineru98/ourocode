defmodule Ourocode.Dashboard.ChildSessionRelationshipRecovery do
  @moduledoc """
  Prepares recovered parent/child relationships for child-session pane replay.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionPaneLookup
  alias Ourocode.Dashboard.ChildSessionPaneRenderer
  alias Ourocode.Dashboard.ChildSessionPaneState
  alias Ourocode.Dashboard.ChildSessionReplay

  @type pane_state :: %{
          required(:working) => [map()],
          required(:completed) => [map()],
          optional(:child_pane_registry) => map()
        }

  @spec prepare_event(pane_state(), map()) ::
          {:ok, pane_state(), map()} | {:error, :invalid_relationship_recovery_index}
  def prepare_event(state, relationship) when is_map(relationship) do
    child_id = ChildSessionIdentity.registry_child_id(relationship.child_id)
    relationship = Map.put(relationship, :child_id, child_id)
    state = seed_existing_relationship_registry(state, relationship)

    event =
      relationship
      |> ChildSessionReplay.relationship_pane_event()
      |> drop_replayed_stream_entries(state, relationship)

    {:ok, state, event}
  end

  def prepare_event(_state, _relationship),
    do: {:error, :invalid_relationship_recovery_index}

  @spec existing_relationship_pane([map()], map()) :: map() | nil
  def existing_relationship_pane(panes, relationship) when is_list(panes) do
    Enum.find(panes, &same_relationship?(&1, relationship))
  end

  def existing_relationship_pane(_panes, _relationship), do: nil

  @spec same_relationship?(map(), map()) :: boolean()
  def same_relationship?(%{child_id: child_id, parent_call_id: parent_call_id}, relationship)
      when child_id == relationship.child_id and parent_call_id == relationship.parent_call_id,
      do: true

  def same_relationship?(
        %{external_ids: external_ids, parent_call_id: parent_call_id},
        relationship
      )
      when is_map(external_ids) and parent_call_id == relationship.parent_call_id do
    relationship.external_ids
    |> ChildSessionPaneLookup.strongest_session_identifiers()
    |> Enum.any?(&ChildSessionPaneLookup.external_id_matches?(external_ids, &1))
  end

  def same_relationship?(_pane, _relationship), do: false

  defp seed_existing_relationship_registry(
         %{working: working, completed: completed} = state,
         relationship
       ) do
    registry = ChildSessionPaneState.registry(state)

    if Map.has_key?(registry, relationship.child_id) do
      state
    else
      case existing_relationship_pane(working ++ completed, relationship) do
        %{id: pane_id} when is_binary(pane_id) ->
          Map.put(state, :child_pane_registry, Map.put(registry, relationship.child_id, pane_id))

        _pane ->
          state
      end
    end
  end

  defp drop_replayed_stream_entries(event, state, relationship) do
    existing_entries =
      state
      |> relationship_pane(relationship)
      |> ChildSessionPaneRenderer.stream_entries()

    ChildSessionReplay.drop_replayed_stream_entries(event, existing_entries)
  end

  defp relationship_pane(%{working: working, completed: completed}, relationship)
       when is_list(working) and is_list(completed) do
    existing_relationship_pane(working ++ completed, relationship)
  end

  defp relationship_pane(_state, _relationship), do: nil
end
