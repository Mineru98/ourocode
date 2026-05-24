defmodule Ourocode.Dashboard.ChildSessionPaneRegistration do
  @moduledoc """
  Registers child session panes from trusted runtime metadata.
  """

  alias Ourocode.Dashboard.ChildSessionIdentity
  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.Dashboard.ChildSessionPaneLookup
  alias Ourocode.Dashboard.ChildSessionPaneState
  alias Ourocode.Dashboard.ChildSessionPaneStore

  @spec register(map(), map()) :: {:ok, map()} | {:error, :invalid_child_pane_metadata}
  def register(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        metadata
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(metadata) do
    with {:ok, child_id} <- ChildSessionMetadata.string(metadata, :child_id),
         {:ok, parent_call_id} <- ChildSessionMetadata.string(metadata, :parent_call_id),
         {:ok, runtime_source} <- ChildSessionMetadata.string(metadata, :runtime_source),
         {:ok, transport} <- ChildSessionMetadata.transport(metadata) do
      now =
        ChildSessionMetadata.integer(metadata, :updated_at_ms) || System.system_time(:millisecond)

      created_at_ms = ChildSessionMetadata.integer(metadata, :created_at_ms) || now
      existing_panes = working ++ completed
      registry_child_id = ChildSessionIdentity.registry_child_id(child_id)

      external_ids =
        metadata
        |> ChildSessionMetadata.map_value(:external_ids, %{})
        |> Map.put_new("childID", child_id)

      registry =
        state
        |> ChildSessionPaneState.registry()
        |> register_child_id(
          child_id,
          ChildSessionPaneLookup.reusable_session_pane(existing_panes, external_ids)
        )

      pane_id = Map.fetch!(registry, registry_child_id)
      existing_pane = Enum.find(existing_panes, &(&1.id == pane_id))

      pane = %{
        id: pane_id,
        kind: :child_session,
        status: :working,
        child_id: registry_child_id,
        parent_call_id: parent_call_id,
        runtime_source: runtime_source,
        transport: transport,
        external_ids: external_ids,
        stream_cursor:
          metadata
          |> ChildSessionMetadata.map_value(:stream_cursor, %{})
          |> Map.merge(%{
            transport: transport,
            child_id: registry_child_id
          }),
        pane_state: ChildSessionMetadata.pane_state(metadata, existing_pane),
        created_at_ms: created_at_ms,
        updated_at_ms: now
      }

      pane_for_insert = ChildSessionPaneStore.merge_existing(existing_panes, pane)

      {:ok,
       state
       |> Map.put(
         :working,
         ChildSessionPaneStore.upsert(working, pane_for_insert, fn existing ->
           ChildSessionPaneStore.merge(existing, pane)
         end)
       )
       |> Map.put(:completed, ChildSessionPaneStore.reject(completed, pane_id))
       |> Map.put(:focused, focused || pane_id)
       |> Map.put(:open, ChildSessionPaneStore.append_once(open, pane_id))
       |> Map.put(:child_pane_registry, registry)}
    else
      _error -> {:error, :invalid_child_pane_metadata}
    end
  end

  def register(_state, _metadata), do: {:error, :invalid_child_pane_metadata}

  defp register_child_id(registry, child_id, %{id: pane_id})
       when is_map(registry) and is_binary(child_id) and is_binary(pane_id) do
    ChildSessionIdentity.register_child_id(registry, child_id, %{id: pane_id})
  end

  defp register_child_id(registry, child_id, _reusable_pane),
    do: ChildSessionIdentity.register_child_id(registry, child_id)
end
