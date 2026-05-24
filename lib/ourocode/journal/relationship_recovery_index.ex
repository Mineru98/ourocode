defmodule Ourocode.Journal.RelationshipRecoveryIndex do
  @moduledoc """
  Rebuilds parent MCP call to child agent/session mappings from decoded records.

  The decoder owns journal-shape validation. This module consumes decoded
  relationship recovery records and builds the lookup indexes needed by UI
  recovery without re-trusting runtime status beyond the latest decoded record.
  """

  alias Ourocode.Journal.RelationshipRecoveryRecord
  alias Ourocode.Journal.RelationshipState

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
      case RelationshipState.from_record(record) do
        {:ok, relationship} ->
          key = {relationship.parent_call_id, relationship.child_id}
          existing = Map.get(by_key, key)
          keys = if existing, do: keys, else: keys ++ [key]

          relationship =
            if existing, do: RelationshipState.merge(existing, relationship), else: relationship

          {:cont,
           {:ok, Map.put(by_key, key, relationship), keys,
            max(high_watermark, relationship.latest_event_seq)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
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
end
