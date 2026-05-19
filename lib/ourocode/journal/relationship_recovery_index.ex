defmodule Ourocode.Journal.RelationshipRecoveryIndex do
  @moduledoc """
  Rebuilds parent MCP call to child agent/session mappings from decoded records.

  The decoder owns journal-shape validation. This module consumes decoded
  relationship recovery records and builds the lookup indexes needed by UI
  recovery without re-trusting runtime status beyond the latest decoded record.
  """

  alias Ourocode.Journal.RelationshipRecoveryRecord

  @enforce_keys [
    :relationships,
    :by_parent_call_id,
    :by_child_id,
    :by_pane_id,
    :acknowledged_stream_cursors_by_child_id,
    :acknowledged_stream_cursors_by_pane_id,
    :event_seq_high_watermark
  ]
  defstruct [
    :relationships,
    :by_parent_call_id,
    :by_child_id,
    :by_pane_id,
    :acknowledged_stream_cursors_by_child_id,
    :acknowledged_stream_cursors_by_pane_id,
    :event_seq_high_watermark
  ]

  @type relationship :: %{
          required(:parent_call_id) => String.t(),
          required(:child_id) => String.t(),
          required(:pane_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => RelationshipRecoveryRecord.transport(),
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:acknowledged_stream_cursor) => map() | nil,
          required(:pane_state) => map(),
          required(:status) => atom() | nil,
          required(:first_event_seq) => non_neg_integer(),
          required(:latest_event_seq) => non_neg_integer(),
          required(:event_seqs) => [non_neg_integer()],
          required(:source_event_types) => [atom()],
          required(:occurred_at_ms) => integer(),
          required(:created_at_ms) => integer() | nil,
          required(:updated_at_ms) => integer() | nil
        }

  @type parent_mapping :: %{
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:transport) => RelationshipRecoveryRecord.transport(),
          required(:children) => [relationship()],
          required(:child_ids) => [String.t()],
          required(:latest_event_seq) => non_neg_integer(),
          required(:status) => atom() | nil
        }

  @type t :: %__MODULE__{
          relationships: [relationship()],
          by_parent_call_id: %{optional(String.t()) => parent_mapping()},
          by_child_id: %{optional(String.t()) => [relationship()]},
          by_pane_id: %{optional(String.t()) => relationship()},
          acknowledged_stream_cursors_by_child_id: %{optional(String.t()) => map()},
          acknowledged_stream_cursors_by_pane_id: %{optional(String.t()) => map()},
          event_seq_high_watermark: non_neg_integer()
        }

  @doc """
  Returns an empty recovery index.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{
      relationships: [],
      by_parent_call_id: %{},
      by_child_id: %{},
      by_pane_id: %{},
      acknowledged_stream_cursors_by_child_id: %{},
      acknowledged_stream_cursors_by_pane_id: %{},
      event_seq_high_watermark: 0
    }
  end

  @doc """
  Builds lookup indexes from decoded relationship recovery records.

  Repeated events for the same `{parent_call_id, child_id}` merge into one
  relationship. Later events advance cursors, pane state, status, timestamps,
  and pane identity while preserving sequence history for recovery checks.
  """
  @spec build([RelationshipRecoveryRecord.t()]) :: {:ok, t()} | {:error, term()}
  def build(records) when is_list(records) do
    with {:ok, relationships_by_key, ordered_keys, high_watermark} <- reduce_records(records) do
      relationships = Enum.map(ordered_keys, &Map.fetch!(relationships_by_key, &1))

      {:ok,
       %__MODULE__{
         relationships: relationships,
         by_parent_call_id: build_parent_index(relationships),
         by_child_id: build_child_index(relationships),
         by_pane_id: build_pane_index(relationships),
         acknowledged_stream_cursors_by_child_id:
           build_acknowledged_child_cursor_index(relationships),
         acknowledged_stream_cursors_by_pane_id:
           build_acknowledged_pane_cursor_index(relationships),
         event_seq_high_watermark: high_watermark
       }}
    end
  end

  def build(_records), do: {:error, :invalid_relationship_recovery_records}

  @doc """
  Fetches a recovered parent mapping by local parent MCP call ID.
  """
  @spec parent(t(), String.t()) :: {:ok, parent_mapping()} | :error
  def parent(%__MODULE__{by_parent_call_id: index}, parent_call_id)
      when is_binary(parent_call_id) do
    fetch(index, parent_call_id)
  end

  @doc """
  Fetches recovered mappings that mention a child agent/session ID.
  """
  @spec child(t(), String.t()) :: {:ok, [relationship()]} | :error
  def child(%__MODULE__{by_child_id: index}, child_id) when is_binary(child_id) do
    fetch(index, child_id)
  end

  @doc """
  Fetches a recovered mapping by local pane ID.
  """
  @spec pane(t(), String.t()) :: {:ok, relationship()} | :error
  def pane(%__MODULE__{by_pane_id: index}, pane_id) when is_binary(pane_id) do
    fetch(index, pane_id)
  end

  @doc """
  Fetches the last acknowledged stream cursor recovered for one pane.
  """
  @spec acknowledged_stream_cursor_for_pane(t(), String.t()) :: {:ok, map()} | :error
  def acknowledged_stream_cursor_for_pane(
        %__MODULE__{acknowledged_stream_cursors_by_pane_id: index},
        pane_id
      )
      when is_binary(pane_id) do
    fetch(index, pane_id)
  end

  @doc """
  Fetches the last acknowledged stream cursor recovered for one child/session.
  """
  @spec acknowledged_stream_cursor_for_child(t(), String.t()) :: {:ok, map()} | :error
  def acknowledged_stream_cursor_for_child(
        %__MODULE__{acknowledged_stream_cursors_by_child_id: index},
        child_id
      )
      when is_binary(child_id) do
    fetch(index, child_id)
  end

  defp reduce_records(records) do
    Enum.reduce_while(records, {:ok, %{}, [], 0}, fn record,
                                                     {:ok, by_key, keys, high_watermark} ->
      case relationship_from_record(record) do
        {:ok, relationship} ->
          key = {relationship.parent_call_id, relationship.child_id}
          existing = Map.get(by_key, key)
          keys = if existing, do: keys, else: keys ++ [key]

          relationship =
            if existing, do: merge_relationship(existing, relationship), else: relationship

          {:cont,
           {:ok, Map.put(by_key, key, relationship), keys,
            max(high_watermark, relationship.latest_event_seq)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp relationship_from_record(%RelationshipRecoveryRecord{} = record) do
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

  defp relationship_from_record(_record), do: {:error, :invalid_relationship_recovery_record}

  defp merge_relationship(existing, incoming) do
    %{
      existing
      | pane_id: incoming.pane_id || existing.pane_id,
        runtime_source: incoming.runtime_source || existing.runtime_source,
        transport: incoming.transport || existing.transport,
        external_ids: Map.merge(existing.external_ids, incoming.external_ids),
        stream_cursor: Map.merge(existing.stream_cursor, incoming.stream_cursor),
        acknowledged_stream_cursor:
          incoming.acknowledged_stream_cursor || existing.acknowledged_stream_cursor,
        pane_state: merge_pane_state(existing.pane_state, incoming.pane_state),
        status: incoming.status || existing.status,
        latest_event_seq: max(existing.latest_event_seq, incoming.latest_event_seq),
        event_seqs: existing.event_seqs ++ incoming.event_seqs,
        source_event_types: existing.source_event_types ++ incoming.source_event_types,
        occurred_at_ms: incoming.occurred_at_ms || existing.occurred_at_ms,
        created_at_ms: earliest(existing.created_at_ms, incoming.created_at_ms),
        updated_at_ms: latest(existing.updated_at_ms, incoming.updated_at_ms)
    }
  end

  defp build_parent_index(relationships) do
    relationships
    |> Enum.group_by(& &1.parent_call_id)
    |> Map.new(fn {parent_call_id, children} ->
      children = Enum.sort_by(children, & &1.first_event_seq)
      latest = Enum.max_by(children, & &1.latest_event_seq)

      {parent_call_id,
       %{
         parent_call_id: parent_call_id,
         runtime_source: latest.runtime_source,
         transport: latest.transport,
         children: children,
         child_ids: Enum.map(children, & &1.child_id),
         latest_event_seq: latest.latest_event_seq,
         status: latest.status
       }}
    end)
  end

  defp build_child_index(relationships) do
    relationships
    |> Enum.group_by(& &1.child_id)
    |> Map.new(fn {child_id, child_relationships} ->
      {child_id, Enum.sort_by(child_relationships, & &1.first_event_seq)}
    end)
  end

  defp build_pane_index(relationships) do
    Map.new(relationships, fn relationship -> {relationship.pane_id, relationship} end)
  end

  defp build_acknowledged_child_cursor_index(relationships) do
    relationships
    |> Enum.reject(&is_nil(&1.acknowledged_stream_cursor))
    |> Map.new(fn relationship ->
      {relationship.child_id, relationship.acknowledged_stream_cursor}
    end)
  end

  defp build_acknowledged_pane_cursor_index(relationships) do
    relationships
    |> Enum.reject(&is_nil(&1.acknowledged_stream_cursor))
    |> Map.new(fn relationship ->
      {relationship.pane_id, relationship.acknowledged_stream_cursor}
    end)
  end

  defp fetch(index, key) do
    case Map.fetch(index, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp merge_pane_state(existing, incoming) when is_map(existing) and is_map(incoming) do
    stream_entries =
      existing
      |> pane_stream_entries()
      |> Kernel.++(pane_stream_entries(incoming))
      |> dedupe_stream_entries()

    existing
    |> Map.merge(incoming)
    |> Map.delete("stream_entries")
    |> maybe_put_stream_entries(stream_entries)
  end

  defp merge_pane_state(existing, incoming), do: Map.merge(existing || %{}, incoming || %{})

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

  defp earliest(nil, value), do: value
  defp earliest(value, nil), do: value
  defp earliest(left, right), do: min(left, right)

  defp latest(nil, value), do: value
  defp latest(value, nil), do: value
  defp latest(left, right), do: max(left, right)
end
