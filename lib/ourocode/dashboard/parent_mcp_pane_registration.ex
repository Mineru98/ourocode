defmodule Ourocode.Dashboard.ParentMcpPaneRegistration do
  @moduledoc """
  Registers parent MCP panes from trusted runtime metadata.

  Parent pane lifecycle event application lives in `ParentMcpPaneLifecycle`.
  This module owns the direct metadata registration path used by runtime code
  that already knows the parent call identity.
  """

  alias Ourocode.Dashboard.ParentMcpPaneMetadata, as: Metadata

  @doc """
  Registers or updates a parent MCP pane in live pane state.
  """
  @spec register(map(), map()) :: {:ok, map()} | {:error, :invalid_parent_pane_metadata}
  def register(
        %{working: working, completed: completed, focused: focused, open: open} = state,
        metadata
      )
      when is_list(working) and is_list(completed) and is_list(open) and is_map(metadata) do
    with {:ok, parent_call_id} <- Metadata.string(metadata, :parent_call_id),
         {:ok, runtime_source} <- Metadata.string(metadata, :runtime_source),
         {:ok, transport} <- Metadata.transport(metadata) do
      now = Metadata.integer(metadata, :updated_at_ms) || System.system_time(:millisecond)
      created_at_ms = Metadata.integer(metadata, :created_at_ms) || now
      pane_id = pane_id(parent_call_id)

      pane =
        pane(metadata, parent_call_id, pane_id, runtime_source, transport, created_at_ms, now)

      {:ok,
       %{
         state
         | working: upsert_pane(working, merge_existing(working ++ completed, pane)),
           completed: reject_pane(completed, pane_id),
           focused: focused || pane_id,
           open: append_once(open, pane_id)
       }}
    else
      _error -> {:error, :invalid_parent_pane_metadata}
    end
  end

  def register(_state, _metadata), do: {:error, :invalid_parent_pane_metadata}

  defp pane(metadata, parent_call_id, pane_id, runtime_source, transport, created_at_ms, now) do
    %{
      id: pane_id,
      kind: :parent_mcp_call,
      status: :starting,
      parent_call_id: parent_call_id,
      runtime_source: runtime_source,
      transport: transport,
      external_ids: Metadata.map_value(metadata, :external_ids, %{}),
      request_id: Metadata.string_or_nil(metadata, :request_id),
      method: Metadata.string_or_nil(metadata, :method),
      params: Metadata.value(metadata, :params),
      stream_cursor:
        metadata
        |> Metadata.map_value(:stream_cursor, %{})
        |> Map.merge(%{transport: transport, parent_call_id: parent_call_id}),
      pane_state:
        %{
          open?: true,
          focused?: false,
          renderer: :default_parent_mcp,
          lifecycle_type: :parent_pane_registered,
          event_count: 0,
          notification_count: 0
        }
        |> Map.merge(Metadata.map_value(metadata, :pane_state, %{})),
      created_at_ms: created_at_ms,
      updated_at_ms: now
    }
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

  defp append_once(values, value) do
    if value in values do
      values
    else
      values ++ [value]
    end
  end

  defp pane_id(parent_call_id), do: "parent-mcp:" <> parent_call_id
end
