defmodule Ourocode.Journal.RenderedSequences do
  @moduledoc """
  Extracts rendered sequence records from terminal render output.
  """

  alias Ourocode.Journal.EntryIdentity

  @spec summaries(term()) :: [map()]
  def summaries(rendered_output) do
    rendered_output
    |> sources()
    |> Enum.flat_map(&source_summaries/1)
    |> Enum.reject(&is_nil(&1.rendered_sequence_id))
  end

  @spec event_keys(term()) :: MapSet.t({term(), term()})
  def event_keys(rendered_output) do
    rendered_output
    |> sources()
    |> Enum.reduce(MapSet.new(), fn source, acc ->
      source
      |> sequence_keys()
      |> Enum.reduce(acc, &MapSet.put(&2, &1))
    end)
  end

  @spec sources(term()) :: [map()]
  def sources(rendered_output) when is_list(rendered_output) do
    Enum.flat_map(rendered_output, &sources/1)
  end

  def sources(%{type: :rendered_sequence_entry} = entry), do: [entry]
  def sources(%{"type" => "rendered_sequence_entry"} = entry), do: [entry]
  def sources(%{"type" => :rendered_sequence_entry} = entry), do: [entry]

  def sources(rendered_output) when is_map(rendered_output) do
    pane_sequences =
      Map.get(rendered_output, :rendered_sequences) ||
        Map.get(rendered_output, "rendered_sequences")

    child_collections =
      [:working, :completed, "working", "completed"]
      |> Enum.flat_map(fn key ->
        case Map.get(rendered_output, key) do
          panes when is_list(panes) -> panes
          _panes -> []
        end
      end)

    cond do
      is_list(pane_sequences) ->
        [rendered_output]

      child_collections != [] ->
        Enum.flat_map(child_collections, &sources/1)

      true ->
        []
    end
  end

  def sources(_rendered_output), do: []

  defp source_summaries(%{} = rendered_pane) do
    if rendered_sequence_entry?(rendered_pane) do
      rendered_pane
      |> summary()
      |> List.wrap()
    else
      child_id = EntryIdentity.child_id(rendered_pane)
      pane_id = pane_id(rendered_pane)

      rendered_pane
      |> sequences()
      |> Enum.map(fn sequence ->
        summary(sequence, child_id, pane_id)
      end)
    end
  end

  defp source_summaries(_source), do: []

  defp summary(entry) when is_map(entry) do
    %{
      rendered_sequence_id: rendered_sequence_id(entry),
      child_id: EntryIdentity.child_id(entry),
      pane_id: map_value(entry, :pane_id),
      rendered_event_seq: map_value(entry, :rendered_event_seq) || map_value(entry, :event_seq),
      runtime_seq: map_value(entry, :runtime_seq),
      rendered_index: map_value(entry, :rendered_index)
    }
  end

  defp summary(sequence, fallback_child_id, fallback_pane_id) when is_map(sequence) do
    %{
      rendered_sequence_id: rendered_sequence_id(sequence),
      child_id: EntryIdentity.child_id(sequence) || fallback_child_id,
      pane_id: map_value(sequence, :pane_id) || fallback_pane_id,
      rendered_event_seq:
        map_value(sequence, :event_seq) || map_value(sequence, :rendered_event_seq),
      runtime_seq: map_value(sequence, :runtime_seq),
      rendered_index: map_value(sequence, :rendered_index)
    }
  end

  defp sequence_keys(%{type: :rendered_sequence_entry} = entry) do
    [{EntryIdentity.child_id(entry), map_value(entry, :rendered_event_seq)}]
  end

  defp sequence_keys(%{"type" => "rendered_sequence_entry"} = entry) do
    [{EntryIdentity.child_id(entry), map_value(entry, :rendered_event_seq)}]
  end

  defp sequence_keys(%{"type" => :rendered_sequence_entry} = entry) do
    [{EntryIdentity.child_id(entry), map_value(entry, :rendered_event_seq)}]
  end

  defp sequence_keys(%{} = rendered_pane) do
    child_id = EntryIdentity.child_id(rendered_pane)

    rendered_pane
    |> sequences()
    |> Enum.map(fn sequence ->
      {EntryIdentity.child_id(sequence) || child_id,
       map_value(sequence, :event_seq) || map_value(sequence, :rendered_event_seq)}
    end)
  end

  defp sequence_keys(_source), do: []

  defp sequences(rendered_pane) do
    case Map.get(rendered_pane, :rendered_sequences) ||
           Map.get(rendered_pane, "rendered_sequences") do
      sequences when is_list(sequences) -> sequences
      _sequences -> []
    end
  end

  defp rendered_sequence_id(entry) when is_map(entry) do
    map_value(entry, :rendered_sequence_id) || map_value(entry, :id)
  end

  defp rendered_sequence_entry?(entry) do
    event_type(entry) in [:rendered_sequence_entry, "rendered_sequence_entry"]
  end

  defp pane_id(rendered_pane), do: Map.get(rendered_pane, :id) || Map.get(rendered_pane, "id")

  defp event_type(entry) do
    map_value(entry, :type) || map_value(entry, :event_type)
  end

  defp map_value(map, key), do: EntryIdentity.map_value(map, key)
end
