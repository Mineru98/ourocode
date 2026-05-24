defmodule Ourocode.Journal.RenderedSequenceRecords do
  @moduledoc """
  Builds journal records for rendered child pane sequence entries.
  """

  @spec records(map()) :: [map()]
  def records(rendered_pane) when is_map(rendered_pane) do
    rendered_pane
    |> rendered_sequences()
    |> Enum.with_index()
    |> Enum.map(fn {sequence, index} ->
      stream_entry = Enum.at(rendered_stream_entries(rendered_pane), index)

      %{
        type: :rendered_sequence_entry,
        source: :pane_model,
        pane_id: map_value(sequence, :pane_id) || map_value(rendered_pane, :id),
        child_id: map_value(sequence, :child_id) || map_value(rendered_pane, :child_id),
        child_event_id: map_value(sequence, :child_event_id) || child_event_id(stream_entry),
        rendered_sequence_id: map_value(sequence, :id),
        rendered_event_seq: map_value(sequence, :event_seq),
        runtime_seq: map_value(sequence, :runtime_seq),
        rendered_index: map_value(sequence, :rendered_index),
        rendered_sequence: sequence,
        payload: stream_entry,
        occurred_at_ms: occurred_at_ms(stream_entry, rendered_pane)
      }
    end)
  end

  def records(_rendered_pane), do: []

  defp rendered_sequences(rendered_pane) do
    case map_value(rendered_pane, :rendered_sequences) do
      sequences when is_list(sequences) -> sequences
      _sequences -> []
    end
  end

  defp rendered_stream_entries(rendered_pane) do
    pane_state = map_value(rendered_pane, :pane_state) || %{}

    case map_value(pane_state, :stream_entries) do
      entries when is_list(entries) -> entries
      _entries -> []
    end
  end

  defp occurred_at_ms(%{} = stream_entry, rendered_pane) do
    map_value(stream_entry, :occurred_at_ms) || map_value(rendered_pane, :updated_at_ms)
  end

  defp occurred_at_ms(_stream_entry, rendered_pane), do: map_value(rendered_pane, :updated_at_ms)

  defp child_event_id(%{} = stream_entry), do: map_value(stream_entry, :child_event_id)
  defp child_event_id(_stream_entry), do: nil

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
