defmodule Ourocode.Journal.RenderReconciliation do
  @moduledoc """
  Reconciles journaled child stream/render records with rendered pane output.
  """

  alias Ourocode.Journal.EntryIdentity
  alias Ourocode.Journal.RenderedSequences

  @spec verify_rendered_sequences_journaled([map()], term()) :: {:ok, map()} | {:error, map()}
  def verify_rendered_sequences_journaled(journal_entries, rendered_output)
      when is_list(journal_entries) do
    journaled_ids =
      journal_entries
      |> Enum.flat_map(&journaled_rendered_sequence_ids/1)
      |> MapSet.new()

    rendered_sequences = RenderedSequences.summaries(rendered_output)

    missing =
      rendered_sequences
      |> Enum.reject(&MapSet.member?(journaled_ids, &1.rendered_sequence_id))

    report = %{
      type: :rendered_sequence_journal_reconciliation,
      status: if(missing == [], do: :ok, else: :failed),
      journaled_rendered_sequence_count: MapSet.size(journaled_ids),
      rendered_sequence_count: length(rendered_sequences),
      journaled_rendered_sequence_ids: journaled_ids |> MapSet.to_list() |> Enum.sort(),
      rendered_sequence_ids:
        rendered_sequences
        |> Enum.map(& &1.rendered_sequence_id)
        |> Enum.uniq()
        |> Enum.sort(),
      missing_journaled_rendered_sequences: missing
    }

    if missing == [] do
      {:ok, report}
    else
      {:error,
       report
       |> Map.put(:reason, :rendered_sequences_missing_from_journal)
       |> Map.put(:missing_count, length(missing))}
    end
  end

  @spec reconcile_completed_child_streams([map()], term()) :: {:ok, map()} | {:error, map()}
  def reconcile_completed_child_streams(journal_entries, rendered_output)
      when is_list(journal_entries) do
    completed_child_ids = completed_child_ids(journal_entries)
    rendered_event_keys = RenderedSequences.event_keys(rendered_output)

    missing =
      journal_entries
      |> Enum.filter(&journaled_child_stream_event?(&1, completed_child_ids))
      |> Enum.reject(&MapSet.member?(rendered_event_keys, journaled_event_key(&1)))
      |> Enum.map(&missing_rendered_event/1)

    report = %{
      type: :journal_to_render_reconciliation,
      status: if(missing == [], do: :ok, else: :failed),
      completed_child_ids: MapSet.to_list(completed_child_ids) |> Enum.sort(),
      journaled_event_count:
        Enum.count(journal_entries, &journaled_child_stream_event?(&1, completed_child_ids)),
      rendered_event_count: MapSet.size(rendered_event_keys),
      missing_rendered_events: missing
    }

    if missing == [] do
      {:ok, report}
    else
      {:error,
       report
       |> Map.put(:reason, :journaled_child_stream_events_missing_from_render)
       |> Map.put(:missing_count, length(missing))}
    end
  end

  defp completed_child_ids(entries) do
    entries
    |> Enum.reduce(MapSet.new(), fn entry, acc ->
      if child_completion_event?(entry) do
        case EntryIdentity.child_id(entry) do
          nil -> acc
          child_id -> MapSet.put(acc, child_id)
        end
      else
        acc
      end
    end)
  end

  defp child_completion_event?(entry) when is_map(entry) do
    event_type(entry) == :child_pane_completed or
      (event_type(entry) == :child_pane_updated and entry_status(entry) == :completed)
  end

  defp child_completion_event?(_entry), do: false

  defp journaled_child_stream_event?(entry, completed_child_ids) when is_map(entry) do
    event_type(entry) == :parent_call_event and
      child_stream_payload?(entry) and
      MapSet.member?(completed_child_ids, EntryIdentity.child_id(entry))
  end

  defp journaled_child_stream_event?(_entry, _completed_child_ids), do: false

  defp child_stream_payload?(entry) do
    payload = map_value(entry, :payload)

    is_map(payload) and payload != %{}
  end

  defp journaled_event_key(entry),
    do: {EntryIdentity.child_id(entry), map_value(entry, :event_seq)}

  defp journaled_rendered_sequence_ids(%{} = entry) do
    if rendered_sequence_entry?(entry) do
      entry
      |> rendered_sequence_id()
      |> List.wrap()
    else
      []
    end
  end

  defp journaled_rendered_sequence_ids(_entry), do: []

  defp rendered_sequence_id(entry) when is_map(entry) do
    map_value(entry, :rendered_sequence_id) || map_value(entry, :id)
  end

  defp rendered_sequence_entry?(entry) do
    event_type(entry) in [:rendered_sequence_entry, "rendered_sequence_entry"]
  end

  defp missing_rendered_event(entry) do
    %{
      child_event_id: EntryIdentity.child_event_identity_value(entry),
      child_id: EntryIdentity.child_id(entry),
      event_seq: map_value(entry, :event_seq),
      parent_call_id: map_value(entry, :parent_call_id),
      transport: map_value(entry, :transport),
      occurred_at_ms: map_value(entry, :occurred_at_ms)
    }
  end

  defp event_type(entry) do
    map_value(entry, :type) || map_value(entry, :event_type)
  end

  defp entry_status(entry), do: map_value(entry, :status)

  defp map_value(map, key), do: EntryIdentity.map_value(map, key)
end
