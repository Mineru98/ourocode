defmodule Ourocode.Dashboard.ChildSessionPaneStore do
  @moduledoc """
  Pure list and merge operations for child-session pane records.
  """

  alias Ourocode.Dashboard.ChildSessionMetadata
  alias Ourocode.Dashboard.ChildSessionPaneRenderer
  alias Ourocode.Journal.RelationshipPaneState

  @spec distinct([map()]) :: [map()]
  def distinct(panes) when is_list(panes) do
    panes
    |> Enum.reduce({[], MapSet.new()}, fn
      %{id: id} = pane, {acc, seen} when is_binary(id) ->
        if MapSet.member?(seen, id) do
          {acc, seen}
        else
          {[pane | acc], MapSet.put(seen, id)}
        end

      _pane, acc ->
        acc
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @spec reject_registered([map()], [map()]) :: [map()]
  def reject_registered(panes, registered_panes)
      when is_list(panes) and is_list(registered_panes) do
    registered_ids =
      registered_panes
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Enum.reject(panes, &MapSet.member?(registered_ids, &1.id))
  end

  @spec mark_focused([map()], String.t() | nil) :: [map()]
  def mark_focused(panes, pane_id) when is_list(panes) do
    Enum.map(panes, fn
      %{id: id, pane_state: pane_state} = pane when is_map(pane_state) ->
        put_in(pane, [:pane_state, :focused?], id == pane_id)

      pane ->
        pane
    end)
  end

  @spec focused_pane_map(map(), String.t()) :: map()
  def focused_pane_map(%{pane_state: pane_state}, _pane_id) when is_map(pane_state) do
    Map.put(pane_state, :focused?, true)
  end

  def focused_pane_map(_pane, _pane_id), do: %{focused?: true}

  @spec merge_existing([map()], map()) :: map()
  def merge_existing(panes, pane) when is_list(panes) and is_map(pane) do
    case Enum.find(panes, &(&1.id == pane.id)) do
      nil -> pane
      existing -> merge(existing, pane)
    end
  end

  @spec merge(map(), map()) :: map()
  def merge(existing, pane) when is_map(existing) and is_map(pane) do
    existing
    |> Map.merge(%{
      status: :working,
      child_id: pane.child_id,
      updated_at_ms: pane.updated_at_ms,
      stream_cursor: Map.merge(existing.stream_cursor || %{}, pane.stream_cursor || %{}),
      external_ids: Map.merge(existing.external_ids, pane.external_ids)
    })
    |> Map.put(
      :pane_state,
      existing.pane_state
      |> Map.merge(mergeable_pane_state(existing.pane_state, pane.pane_state))
      |> Map.put(
        :stream_entries,
        (stream_entries(existing) ++ stream_entries(pane))
        |> dedupe_stream_entries()
        |> RelationshipPaneState.cap_stream_entries()
      )
    )
  end

  @spec apply_updates(map(), map()) :: map()
  def apply_updates(pane, updates) when is_map(pane) and is_map(updates) do
    transport = metadata_update_transport(updates, pane.transport)

    pane
    |> Map.merge(%{
      status: metadata_update_status(updates, pane.status),
      runtime_source: metadata_update_string(updates, :runtime_source, pane.runtime_source),
      transport: transport,
      external_ids:
        Map.merge(pane.external_ids, ChildSessionMetadata.map_value(updates, :external_ids, %{})),
      stream_cursor:
        pane.stream_cursor
        |> Map.merge(ChildSessionMetadata.map_value(updates, :stream_cursor, %{}))
        |> Map.put(:transport, transport)
        |> Map.put(:child_id, pane.child_id),
      pane_state:
        Map.merge(pane.pane_state, ChildSessionMetadata.map_value(updates, :pane_state, %{})),
      updated_at_ms: ChildSessionMetadata.integer(updates, :updated_at_ms) || pane.updated_at_ms
    })
    |> Map.put(:id, pane.id)
    |> Map.put(:kind, :child_session)
    |> Map.put(:child_id, pane.child_id)
    |> Map.put(:parent_call_id, pane.parent_call_id)
    |> Map.put(:created_at_ms, pane.created_at_ms)
  end

  @spec reject([map()], String.t()) :: [map()]
  def reject(panes, pane_id), do: Enum.reject(panes, &(&1.id == pane_id))

  @spec replace([map()], String.t(), map()) :: [map()]
  def replace(panes, pane_id, updated_pane) do
    Enum.map(panes, fn
      %{id: ^pane_id} -> updated_pane
      pane -> pane
    end)
  end

  @spec upsert([map()], map(), (map() -> map())) :: [map()]
  def upsert([], pane, _update), do: [pane]

  def upsert([%{id: id} = existing | rest], %{id: id}, update) do
    [update.(existing) | rest]
  end

  def upsert([pane | rest], new_pane, update) do
    [pane | upsert(rest, new_pane, update)]
  end

  @spec append_once([term()], term()) :: [term()]
  def append_once(values, value) do
    if value in values do
      values
    else
      values ++ [value]
    end
  end

  defp metadata_update_string(updates, key, default) do
    case ChildSessionMetadata.value(updates, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          value -> value
        end

      _value ->
        default
    end
  end

  defp metadata_update_transport(updates, default) do
    case ChildSessionMetadata.transport(updates) do
      {:ok, transport} -> transport
      :error -> default
    end
  end

  defp metadata_update_status(updates, default) do
    case ChildSessionMetadata.value(updates, :status) do
      status when status in [:working, :completed] -> status
      "working" -> :working
      "completed" -> :completed
      _status -> default
    end
  end

  defp dedupe_stream_entries(entries) do
    entries
    |> Enum.reduce({[], MapSet.new()}, fn entry, {acc, seen} ->
      key = stream_entry_dedupe_key(entry)

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[entry | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp stream_entry_dedupe_key(entry) when is_map(entry) do
    case Map.get(entry, :child_event_id) || Map.get(entry, "child_event_id") do
      child_event_id when is_binary(child_event_id) and child_event_id != "" ->
        {:child_event_id, child_event_id}

      _child_event_id ->
        {:replay, stream_entry_replay_key(entry)}
    end
  end

  defp stream_entry_dedupe_key(entry), do: {:replay, stream_entry_replay_key(entry)}

  defp mergeable_pane_state(existing_pane_state, pane_state) do
    pane_state
    |> Map.delete(:stream_entries)
    |> maybe_drop_default_renderer(existing_pane_state)
    |> maybe_drop_nil_ack_cursor(existing_pane_state)
  end

  defp maybe_drop_default_renderer(
         %{renderer: :default_child_session} = pane_state,
         existing_pane_state
       )
       when is_map_key(existing_pane_state, :renderer) do
    Map.delete(pane_state, :renderer)
  end

  defp maybe_drop_default_renderer(pane_state, _existing_pane_state), do: pane_state

  defp maybe_drop_nil_ack_cursor(
         %{last_acknowledged_stream_cursor: nil} = pane_state,
         existing_pane_state
       )
       when is_map_key(existing_pane_state, :last_acknowledged_stream_cursor) do
    Map.delete(pane_state, :last_acknowledged_stream_cursor)
  end

  defp maybe_drop_nil_ack_cursor(pane_state, _existing_pane_state), do: pane_state

  defp stream_entries(pane), do: ChildSessionPaneRenderer.stream_entries(pane)

  defp stream_entry_replay_key(entry) when is_map(entry) do
    {
      Map.get(entry, :event_seq) || Map.get(entry, "event_seq"),
      Map.get(entry, :runtime_seq) || Map.get(entry, "runtime_seq"),
      Map.get(entry, :token) || Map.get(entry, "token"),
      Map.get(entry, :delta) || Map.get(entry, "delta"),
      Map.get(entry, :content) || Map.get(entry, "content")
    }
  end

  defp stream_entry_replay_key(entry), do: entry
end
