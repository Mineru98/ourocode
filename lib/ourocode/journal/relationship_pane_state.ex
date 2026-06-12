defmodule Ourocode.Journal.RelationshipPaneState do
  @moduledoc """
  Merges recovered child-pane state snapshots.

  Relationship recovery receives multiple journal records for the same
  parent/child pair. This module owns the pane-state merge rules, including
  preserving stream entries without duplicating replayed events.
  """

  # In-memory pane state keeps only the newest stream entries; the journal
  # file on disk remains the full history. Live pane merges and recovery
  # merges share this cap so a recovered pane holds the same window the live
  # pane held when it was journaled.
  @max_stream_entries 500

  @spec merge(map() | nil, map() | nil) :: map()
  def merge(existing, incoming) when is_map(existing) and is_map(incoming) do
    stream_entries =
      existing
      |> pane_stream_entries()
      |> Kernel.++(pane_stream_entries(incoming))
      |> dedupe_stream_entries()
      |> cap_stream_entries()

    existing
    |> Map.merge(incoming)
    |> Map.delete("stream_entries")
    |> maybe_put_stream_entries(stream_entries)
  end

  def merge(existing, incoming), do: Map.merge(existing || %{}, incoming || %{})

  @doc "Most-recent-window cap shared by live and recovery pane-state merges."
  @spec cap_stream_entries([term()]) :: [term()]
  def cap_stream_entries(entries) when is_list(entries),
    do: Enum.take(entries, -@max_stream_entries)

  defp pane_stream_entries(pane_state) when is_map(pane_state) do
    case Map.get(pane_state, :stream_entries) || Map.get(pane_state, "stream_entries") do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  defp pane_stream_entries(_pane_state), do: []

  defp maybe_put_stream_entries(pane_state, []), do: pane_state

  defp maybe_put_stream_entries(pane_state, entries),
    do: Map.put(pane_state, :stream_entries, entries)

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
        {:stream_entry, stream_entry_value(entry, :event_seq),
         stream_entry_value(entry, :runtime_seq), stream_entry_value(entry, :token),
         stream_entry_value(entry, :delta), stream_entry_value(entry, :content)}
    end
  end

  defp stream_entry_dedupe_key(entry), do: {:stream_entry, entry}

  defp stream_entry_value(entry, key) when is_map(entry) and is_atom(key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end
end
