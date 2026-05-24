defmodule Ourocode.Dashboard.ChildSessionReplay do
  @moduledoc """
  Recovery helpers for replayed child session stream state.
  """

  alias Ourocode.Dashboard.ChildSessionMetadata

  @spec relationship_pane_event(map()) :: map()
  def relationship_pane_event(relationship) do
    %{
      type: relationship_status_type(relationship.status),
      pane_id: relationship.pane_id,
      child_id: relationship.child_id,
      parent_call_id: relationship.parent_call_id,
      runtime_source: relationship.runtime_source,
      transport: relationship.transport,
      external_ids: relationship.external_ids,
      stream_cursor: relationship.stream_cursor,
      pane_state:
        %{
          last_event_seq: relationship.latest_event_seq,
          last_acknowledged_stream_cursor: relationship.acknowledged_stream_cursor
        }
        |> Map.merge(relationship.pane_state || %{}),
      created_at_ms: relationship.created_at_ms,
      updated_at_ms: relationship.updated_at_ms || relationship.occurred_at_ms,
      occurred_at_ms: relationship.occurred_at_ms,
      status: relationship.status || :working
    }
  end

  @spec drop_replayed_stream_entries(map(), [map()]) :: map()
  def drop_replayed_stream_entries(event, existing_entries) when is_map(event) do
    incoming_entries =
      case get_in(event, [:pane_state, :stream_entries]) do
        entries when is_list(entries) ->
          Enum.map(entries, &ChildSessionMetadata.normalize_stream_entry/1)

        _entries ->
          []
      end

    if incoming_entries != [] and all_stream_entries_replayed?(incoming_entries, existing_entries) do
      update_in(event, [:pane_state], &Map.delete(&1, :stream_entries))
    else
      event
    end
  end

  @spec replayed_at_or_before_acknowledged_cursor?(map(), map() | nil) :: boolean()
  def replayed_at_or_before_acknowledged_cursor?(pane, existing_pane) do
    with %{pane_state: existing_pane_state} when is_map(existing_pane_state) <- existing_pane,
         cursor when is_map(cursor) <- acknowledged_stream_cursor(existing_pane_state),
         ack_seq when is_integer(ack_seq) <- cursor_event_seq(cursor),
         event_seq when is_integer(event_seq) <- pane_event_seq(pane) do
      event_seq <= ack_seq
    else
      _value -> false
    end
  end

  @spec surface_replay_cursor_gap(map(), map() | nil, String.t()) :: map()
  def surface_replay_cursor_gap(pane, existing_pane, pane_id) do
    case replay_cursor_gap(pane, existing_pane, pane_id) do
      nil ->
        pane

      gap ->
        put_in(pane, [:pane_state, :replay_gap_error], gap)
    end
  end

  defp relationship_status_type(:completed), do: :child_pane_completed
  defp relationship_status_type(_status), do: :child_pane_registered

  defp replay_cursor_gap(pane, existing_pane, pane_id) do
    with %{pane_state: existing_pane_state} when is_map(existing_pane_state) <- existing_pane,
         baseline_seq when is_integer(baseline_seq) <- replay_gap_baseline_seq(existing_pane),
         event_seq when is_integer(event_seq) <- pane_event_seq(pane),
         true <- event_seq > baseline_seq + 1 do
      missing_from = baseline_seq + 1
      missing_to = event_seq - 1

      %{
        type: :recoverable_stream_gap,
        pane_id: pane_id,
        child_id: pane.child_id,
        expected_event_seq: missing_from,
        received_event_seq: event_seq,
        missing_event_seq_range: %{from: missing_from, to: missing_to},
        missing_event_seqs: Enum.to_list(missing_from..missing_to//1),
        acknowledged_stream_cursor: acknowledged_stream_cursor(existing_pane_state),
        recovery: :resume_from_acknowledged_stream_cursor
      }
    else
      _value -> nil
    end
  end

  defp replay_gap_baseline_seq(%{pane_state: pane_state} = pane) when is_map(pane_state) do
    cursor_event_seq(acknowledged_stream_cursor(pane_state)) || pane_event_seq(pane)
  end

  defp replay_gap_baseline_seq(_pane), do: nil

  defp pane_event_seq(pane) do
    cursor_event_seq(Map.get(pane, :stream_cursor)) ||
      cursor_event_seq(Map.get(pane, :pane_state))
  end

  defp cursor_event_seq(cursor) when is_map(cursor) do
    ChildSessionMetadata.integer(cursor, :event_seq)
  end

  defp cursor_event_seq(_cursor), do: nil

  defp acknowledged_stream_cursor(pane_state) when is_map(pane_state) do
    Map.get(pane_state, :last_acknowledged_stream_cursor) ||
      Map.get(pane_state, "last_acknowledged_stream_cursor") ||
      Map.get(pane_state, :acknowledged_stream_cursor) ||
      Map.get(pane_state, "acknowledged_stream_cursor")
  end

  defp acknowledged_stream_cursor(_pane_state), do: nil

  defp all_stream_entries_replayed?(incoming_entries, existing_entries) do
    existing_keys =
      existing_entries
      |> Enum.map(&stream_entry_replay_key/1)
      |> MapSet.new()

    Enum.all?(incoming_entries, &MapSet.member?(existing_keys, stream_entry_replay_key(&1)))
  end

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
