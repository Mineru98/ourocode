defmodule Ourocode.Journal.RelationshipState do
  @moduledoc """
  Relationship recovery state construction and merge rules.
  """

  alias Ourocode.Journal.RelationshipPaneState
  alias Ourocode.Journal.RelationshipRecoveryRecord

  @spec from_record(RelationshipRecoveryRecord.t()) :: {:ok, map()} | {:error, term()}
  def from_record(%RelationshipRecoveryRecord{} = record) do
    {:ok,
     %{
       parent_call_id: record.parent_call_id,
       child_id: record.child_id,
       pane_id: record.pane_id,
       runtime_source: record.runtime_source,
       transport: record.transport,
       external_ids: record.external_ids,
       stream_cursor: record.stream_cursor,
       acknowledged_stream_cursor: record.acknowledged_stream_cursor,
       pane_state: record.pane_state,
       status: record.status,
       first_event_seq: record.event_seq,
       latest_event_seq: record.event_seq,
       event_seqs: [record.event_seq],
       source_event_types: [record.event_type],
       occurred_at_ms: record.occurred_at_ms,
       created_at_ms: record.created_at_ms,
       updated_at_ms: record.updated_at_ms
     }}
  end

  def from_record(_record), do: {:error, :invalid_relationship_recovery_record}

  @spec merge(map(), map()) :: map()
  def merge(existing, incoming) when is_map(existing) and is_map(incoming) do
    %{
      existing
      | pane_id: incoming.pane_id || existing.pane_id,
        runtime_source: incoming.runtime_source || existing.runtime_source,
        transport: incoming.transport || existing.transport,
        external_ids: Map.merge(existing.external_ids, incoming.external_ids),
        stream_cursor: Map.merge(existing.stream_cursor, incoming.stream_cursor),
        acknowledged_stream_cursor:
          incoming.acknowledged_stream_cursor || existing.acknowledged_stream_cursor,
        pane_state: RelationshipPaneState.merge(existing.pane_state, incoming.pane_state),
        status: incoming.status || existing.status,
        latest_event_seq: max(existing.latest_event_seq, incoming.latest_event_seq),
        event_seqs: existing.event_seqs ++ incoming.event_seqs,
        source_event_types: existing.source_event_types ++ incoming.source_event_types,
        occurred_at_ms: incoming.occurred_at_ms || existing.occurred_at_ms,
        created_at_ms: earliest(existing.created_at_ms, incoming.created_at_ms),
        updated_at_ms: latest(existing.updated_at_ms, incoming.updated_at_ms)
    }
  end

  defp earliest(nil, value), do: value
  defp earliest(value, nil), do: value
  defp earliest(left, right), do: min(left, right)

  defp latest(nil, value), do: value
  defp latest(value, nil), do: value
  defp latest(left, right), do: max(left, right)
end
