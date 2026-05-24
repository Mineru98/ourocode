defmodule Ourocode.Journal do
  @moduledoc """
  Local JSONL event journal for ourocode runtime recovery.

  The journal stores normalized lifecycle events as append-only records. Runtime
  IDs and statuses remain trusted from the external source; ourocode persists
  local mappings, cursors, pane inputs, and cleanup-relevant state so the UI can
  recover an ordered stream after a restart.
  """

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Journal.CleanupEventDecoder
  alias Ourocode.Journal.CleanupRecoveryIndex
  alias Ourocode.Journal.EntryIdentity
  alias Ourocode.Journal.NormalizedEventComparison
  alias Ourocode.Journal.Reader
  alias Ourocode.Journal.RelationshipEventDecoder
  alias Ourocode.Journal.RelationshipRecoveryIndex
  alias Ourocode.Journal.RenderReconciliation
  alias Ourocode.Journal.RenderedSequenceRecords
  alias Ourocode.Journal.Writer

  @type entry :: map()

  @doc """
  Appends one normalized event to a JSONL journal file.
  """
  @spec append(Path.t(), map() | LifecycleEvent.t()) :: :ok | {:error, term()}
  def append(path, event) when is_binary(path) do
    Writer.append(path, event)
  end

  @doc """
  Appends one normalized event and returns the durable journal record.

  This is for ingestion boundaries that need to keep using the accepted event
  after persistence. The returned map is restored through the normal replay
  decoder, so callers observe the same `event_seq` and normalized field shape
  that journal replay will later reconstruct.
  """
  @spec append_returning_event(Path.t(), map() | LifecycleEvent.t()) ::
          {:ok, entry()} | {:error, term()}
  def append_returning_event(path, event) when is_binary(path) do
    Writer.append_returning_event(path, event)
  end

  @doc """
  Appends one normalized event, raising if persistence fails.
  """
  @spec append!(Path.t(), map() | LifecycleEvent.t()) :: :ok
  def append!(path, event) when is_binary(path) do
    case append(path, event) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "append journal", path: path
    end
  end

  @doc """
  Returns the stable UI identity for one journaled child stream event.

  The identity is derived from metadata persisted with the normalized journal
  record, not from read order or render position. Reading the same journal
  record repeatedly therefore produces the same child event identity.
  """
  @spec child_event_identity(entry()) :: {:ok, String.t()} | {:error, term()}
  def child_event_identity(entry), do: EntryIdentity.child_event_identity(entry)

  @doc """
  Persists every rendered stream sequence from a rendered child pane.

  The journal keeps its own top-level `event_seq` for no-loss ordering. The
  stream event sequence shown in the UI is persisted as `rendered_event_seq` so
  render-sequence records cannot create false journal gaps.
  """
  @spec append_rendered_sequences(Path.t(), map()) :: :ok | {:error, term()}
  def append_rendered_sequences(path, rendered_pane)
      when is_binary(path) and is_map(rendered_pane) do
    rendered_pane
    |> RenderedSequenceRecords.records()
    |> append_records(path)
  end

  @doc """
  Verifies that every rendered sequence identifier is present in the journal.

  This check proves the render model did not advance beyond durable journal
  state. It compares stable `rendered_sequence_id` values from journaled
  `rendered_sequence_entry` records against the identifiers currently exposed by
  rendered panes.
  """
  @spec verify_rendered_sequences_journaled([entry()], term()) :: {:ok, map()} | {:error, map()}
  def verify_rendered_sequences_journaled(journal_entries, rendered_output)
      when is_list(journal_entries) do
    RenderReconciliation.verify_rendered_sequences_journaled(journal_entries, rendered_output)
  end

  @doc """
  Reconciles completed child streams from the normalized journal with render output.

  Only child streams that have a `child_pane_completed` journal marker are
  checked. For those streams, every journaled `parent_call_event` sequence for
  that child must be present in the rendered sequence set. Missing rendered
  events return a structured failure report instead of being silently ignored.
  """
  @spec reconcile_completed_child_streams([entry()], term()) :: {:ok, map()} | {:error, map()}
  def reconcile_completed_child_streams(journal_entries, rendered_output)
      when is_list(journal_entries) do
    RenderReconciliation.reconcile_completed_child_streams(journal_entries, rendered_output)
  end

  @doc """
  Compares journaled normalized events with the normalized source event stream.

  The comparison is duplicate-safe and order-aware. Events with `event_seq` use
  that sequence as their stable identity; events without one fall back to a
  canonical event fingerprint plus occurrence index. The report distinguishes
  source events missing from the journal, journal records with no source event,
  and records with the same normalized identity but different normalized
  content.
  """
  @spec compare_normalized_events([entry()], [map() | LifecycleEvent.t()]) ::
          {:ok, map()} | {:error, map()}
  def compare_normalized_events(journaled_events, source_events)
      when is_list(journaled_events) and is_list(source_events) do
    NormalizedEventComparison.compare(journaled_events, source_events)
  end

  @doc """
  Normalizes raw source transport events, then runs the no-loss comparison.

  This is the validation pipeline entry point for transport-level evidence:
  stdio JSONL lines/messages, parsed or raw SSE frames, and streamable HTTP
  responses are first converted into canonical lifecycle events. Only then are
  they compared against the journal with `compare_normalized_events/2`.
  """
  @spec compare_source_transport_events(
          [entry()],
          [map() | LifecycleEvent.t()],
          keyword() | map()
        ) ::
          {:ok, map()} | {:error, map()}
  def compare_source_transport_events(journaled_events, source_transport_events, options \\ [])
      when is_list(journaled_events) and is_list(source_transport_events) do
    NormalizedEventComparison.compare_source_transport_events(
      journaled_events,
      source_transport_events,
      options
    )
  end

  @doc """
  Reads journal entries in file order.
  """
  @spec read(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read(path) when is_binary(path), do: Reader.read(path)

  @doc """
  Reads journal entries in file order and verifies a contiguous `event_seq`.
  """
  @spec read_ordered(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def read_ordered(path) when is_binary(path), do: Reader.read_ordered(path)

  @doc """
  Reconstructs normalized events from a journal replay.

  This is intentionally the same ordered restore path used by runtime recovery:
  every persisted normalized field, including transport-specific `raw_event`
  debug metadata, is decoded before the event stream is returned.
  """
  @spec replay_normalized_events(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def replay_normalized_events(path) when is_binary(path), do: read_ordered(path)

  @doc """
  Loads typed parent-call to child-session relationship recovery records.

  Non-relationship journal events are ignored. Relationship events preserve
  trusted external runtime identifiers while exposing the local pane ID,
  cursor, and child/session mapping needed for UI recovery.
  """
  @spec load_relationship_recovery_records(Path.t()) ::
          {:ok, [Ourocode.Journal.RelationshipRecoveryRecord.t()]} | {:error, term()}
  def load_relationship_recovery_records(path) when is_binary(path) do
    with {:ok, entries} <- read_ordered(path) do
      RelationshipEventDecoder.decode_all(entries)
    end
  end

  @doc """
  Builds a parent-call to child-session recovery index from decoded records.
  """
  @spec build_relationship_recovery_index([Ourocode.Journal.RelationshipRecoveryRecord.t()]) ::
          {:ok, RelationshipRecoveryIndex.t()} | {:error, term()}
  def build_relationship_recovery_index(records) when is_list(records) do
    RelationshipRecoveryIndex.build(records)
  end

  @doc """
  Loads decoded relationship records and reconstructs recovery lookup indexes.
  """
  @spec load_relationship_recovery_index(Path.t()) ::
          {:ok, RelationshipRecoveryIndex.t()} | {:error, term()}
  def load_relationship_recovery_index(path) when is_binary(path) do
    with {:ok, records} <- load_relationship_recovery_records(path) do
      build_relationship_recovery_index(records)
    end
  end

  @doc """
  Loads typed cleanup recovery records from journal cleanup and completion events.

  Cleanup recovery trusts external runtime status but keeps ourocode-owned local
  cleanup state: child/session/transport keys, cursors, pane state, released
  resource counts, and replay action markers used after restart.
  """
  @spec load_cleanup_recovery_records(Path.t()) ::
          {:ok, [Ourocode.Journal.CleanupRecoveryRecord.t()]} | {:error, term()}
  def load_cleanup_recovery_records(path) when is_binary(path) do
    with {:ok, entries} <- read_ordered(path) do
      CleanupEventDecoder.decode_all(entries)
    end
  end

  @doc """
  Builds cleanup recovery indexes from decoded cleanup records.
  """
  @spec build_cleanup_recovery_index([Ourocode.Journal.CleanupRecoveryRecord.t()]) ::
          {:ok, CleanupRecoveryIndex.t()} | {:error, term()}
  def build_cleanup_recovery_index(records) when is_list(records) do
    CleanupRecoveryIndex.build(records)
  end

  @doc """
  Loads cleanup records and reconstructs cleanup replay state.
  """
  @spec load_cleanup_recovery_index(Path.t()) ::
          {:ok, CleanupRecoveryIndex.t()} | {:error, term()}
  def load_cleanup_recovery_index(path) when is_binary(path) do
    with {:ok, records} <- load_cleanup_recovery_records(path) do
      build_cleanup_recovery_index(records)
    end
  end

  @doc """
  Verifies that journal `event_seq` values are contiguous in file order.

  A full runtime journal normally starts at 1, while focused journal fragments
  can start at a later high-watermark. Both forms are valid as long as no event
  is skipped within the fragment being read.
  """
  @spec verify_no_event_seq_gaps([entry()]) :: :ok | {:error, term()}
  def verify_no_event_seq_gaps(entries) when is_list(entries),
    do: Reader.verify_no_event_seq_gaps(entries)

  defp append_records(records, path) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case append(path, record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
