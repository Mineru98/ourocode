defmodule Ourocode.Journal.CleanupRecoveryIndex do
  @moduledoc """
  Rebuilds cleanup replay state from decoded journal records.

  Repeated cleanup records for the same key collapse into one completed state.
  This makes restart cleanup idempotent: once a key is recorded as completed,
  replay returns a no-op instead of attempting to release the same resources
  again.
  """

  alias Ourocode.Journal.CleanupRecoveryRecord
  alias Ourocode.Journal.CleanupState

  @enforce_keys [
    :cleanup_states,
    :by_child_id,
    :by_session_id,
    :by_parent_call_id,
    :by_pane_id,
    :event_seq_high_watermark
  ]
  defstruct [
    :cleanup_states,
    :by_child_id,
    :by_session_id,
    :by_parent_call_id,
    :by_pane_id,
    :event_seq_high_watermark
  ]

  @type cleanup_state :: %{
          required(:cleanup_key) => String.t(),
          required(:cleanup_state) => :completed | :pending,
          required(:cleanup_reason) => atom() | nil,
          required(:stream_kind) => atom() | nil,
          required(:parent_call_id) => String.t() | nil,
          required(:child_id) => String.t() | nil,
          required(:session_id) => String.t() | nil,
          required(:pane_id) => String.t() | nil,
          required(:runtime_source) => String.t(),
          required(:transport) => atom() | nil,
          required(:external_ids) => map(),
          required(:stream_cursor) => map(),
          required(:pane_state) => map(),
          required(:released_resources) => map(),
          required(:idempotency_key) => String.t(),
          required(:replay_action) => :noop | :release_runtime_resources,
          required(:first_event_seq) => non_neg_integer(),
          required(:latest_event_seq) => non_neg_integer(),
          required(:event_seqs) => [non_neg_integer()],
          required(:source_event_types) => [atom()],
          required(:occurred_at_ms) => integer()
        }

  @type replay_verdict :: %{
          required(:cleanup_key) => String.t(),
          required(:idempotent?) => boolean(),
          required(:replay_action) => :noop | :release_runtime_resources,
          required(:cleanup_state) => :completed | :pending,
          required(:latest_event_seq) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          cleanup_states: [cleanup_state()],
          by_child_id: %{optional(String.t()) => cleanup_state()},
          by_session_id: %{optional(String.t()) => cleanup_state()},
          by_parent_call_id: %{optional(String.t()) => [cleanup_state()]},
          by_pane_id: %{optional(String.t()) => cleanup_state()},
          event_seq_high_watermark: non_neg_integer()
        }

  @spec new() :: t()
  def new do
    %__MODULE__{
      cleanup_states: [],
      by_child_id: %{},
      by_session_id: %{},
      by_parent_call_id: %{},
      by_pane_id: %{},
      event_seq_high_watermark: 0
    }
  end

  @spec build([CleanupRecoveryRecord.t()]) :: {:ok, t()} | {:error, term()}
  def build(records) when is_list(records) do
    with {:ok, by_key, keys, high_watermark} <- reduce_records(records) do
      cleanup_states = Enum.map(keys, &Map.fetch!(by_key, &1))

      {:ok,
       %__MODULE__{
         cleanup_states: cleanup_states,
         by_child_id: build_single_index(cleanup_states, :child_id),
         by_session_id: build_single_index(cleanup_states, :session_id),
         by_parent_call_id: build_parent_index(cleanup_states),
         by_pane_id: build_single_index(cleanup_states, :pane_id),
         event_seq_high_watermark: high_watermark
       }}
    end
  end

  def build(_records), do: {:error, :invalid_cleanup_recovery_records}

  @spec cleanup(t(), String.t()) :: {:ok, cleanup_state()} | :error
  def cleanup(%__MODULE__{cleanup_states: states}, cleanup_key) when is_binary(cleanup_key) do
    states
    |> Enum.find(&(&1.cleanup_key == cleanup_key))
    |> case do
      nil -> :error
      state -> {:ok, state}
    end
  end

  @spec child(t(), String.t()) :: {:ok, cleanup_state()} | :error
  def child(%__MODULE__{by_child_id: index}, child_id) when is_binary(child_id) do
    fetch(index, child_id)
  end

  @spec session(t(), String.t()) :: {:ok, cleanup_state()} | :error
  def session(%__MODULE__{by_session_id: index}, session_id) when is_binary(session_id) do
    fetch(index, session_id)
  end

  @spec pane(t(), String.t()) :: {:ok, cleanup_state()} | :error
  def pane(%__MODULE__{by_pane_id: index}, pane_id) when is_binary(pane_id) do
    fetch(index, pane_id)
  end

  @spec parent(t(), String.t()) :: {:ok, [cleanup_state()]} | :error
  def parent(%__MODULE__{by_parent_call_id: index}, parent_call_id)
      when is_binary(parent_call_id) do
    fetch(index, parent_call_id)
  end

  @doc """
  Returns the cleanup replay verdict for a recovered key.

  Completed cleanup state is idempotent and replays as `:noop`. Unknown keys are
  not treated as idempotent because no completed journal entry was recovered.
  """
  @spec replay_verdict(t(), String.t()) :: {:ok, replay_verdict()} | {:error, :not_recovered}
  def replay_verdict(index, cleanup_key) when is_binary(cleanup_key) do
    case cleanup(index, cleanup_key) do
      {:ok, state} ->
        {:ok,
         %{
           cleanup_key: cleanup_key,
           idempotent?: state.cleanup_state == :completed and state.replay_action == :noop,
           replay_action: state.replay_action,
           cleanup_state: state.cleanup_state,
           latest_event_seq: state.latest_event_seq
         }}

      :error ->
        {:error, :not_recovered}
    end
  end

  @spec verify_idempotent_replay(t(), String.t()) :: :ok | {:error, term()}
  def verify_idempotent_replay(index, cleanup_key) when is_binary(cleanup_key) do
    case replay_verdict(index, cleanup_key) do
      {:ok, %{idempotent?: true}} -> :ok
      {:ok, verdict} -> {:error, {:cleanup_replay_not_idempotent, verdict}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies every recovered cleanup action replays idempotently after restart.

  This is intentionally a pure check over the reconstructed index. Cleanup
  callers can run it multiple times; completed cleanup records remain no-ops and
  unresolved cleanup records surface as replay defects instead of releasing
  resources twice.
  """
  @spec verify_idempotent_replay(t()) :: :ok | {:error, term()}
  def verify_idempotent_replay(%__MODULE__{cleanup_states: states}) do
    Enum.reduce_while(states, :ok, fn state, :ok ->
      verdict = %{
        cleanup_key: state.cleanup_key,
        idempotent?: state.cleanup_state == :completed and state.replay_action == :noop,
        replay_action: state.replay_action,
        cleanup_state: state.cleanup_state,
        latest_event_seq: state.latest_event_seq
      }

      case verdict do
        %{idempotent?: true} ->
          {:cont, :ok}

        _verdict ->
          {:halt, {:error, {:cleanup_replay_not_idempotent, verdict}}}
      end
    end)
  end

  def verify_idempotent_replay(_index), do: {:error, :invalid_cleanup_recovery_index}

  defp reduce_records(records) do
    Enum.reduce_while(records, {:ok, %{}, [], 0}, fn record,
                                                     {:ok, by_key, keys, high_watermark} ->
      case cleanup_from_record(record) do
        {:ok, cleanup} ->
          key = cleanup.cleanup_key
          existing = Map.get(by_key, key)
          keys = if existing, do: keys, else: keys ++ [key]
          cleanup = if existing, do: CleanupState.merge(existing, cleanup), else: cleanup

          {:cont,
           {:ok, Map.put(by_key, key, cleanup), keys,
            max(high_watermark, cleanup.latest_event_seq)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp cleanup_from_record(%CleanupRecoveryRecord{} = record) do
    {:ok,
     %{
       cleanup_key: record.cleanup_key,
       cleanup_state: record.cleanup_state,
       cleanup_reason: record.cleanup_reason,
       stream_kind: record.stream_kind,
       parent_call_id: record.parent_call_id,
       child_id: record.child_id,
       session_id: record.session_id,
       pane_id: record.pane_id,
       runtime_source: record.runtime_source,
       transport: record.transport,
       external_ids: record.external_ids,
       stream_cursor: record.stream_cursor,
       pane_state: record.pane_state,
       released_resources: record.released_resources,
       stale_cleanup_timeout_ms: record.stale_cleanup_timeout_ms,
       stream_subscription_cleanup_timeout_ms: record.stream_subscription_cleanup_timeout_ms,
       cleanup_started_monotonic_ms: record.cleanup_started_monotonic_ms,
       idempotency_key: record.idempotency_key,
       replay_action: record.replay_action,
       first_event_seq: record.event_seq,
       latest_event_seq: record.event_seq,
       event_seqs: [record.event_seq],
       source_event_types: [record.event_type],
       occurred_at_ms: record.occurred_at_ms
     }}
  end

  defp cleanup_from_record(_record), do: {:error, :invalid_cleanup_recovery_record}

  defp build_single_index(cleanup_states, key) do
    cleanup_states
    |> Enum.reject(&(Map.get(&1, key) in [nil, ""]))
    |> Map.new(fn cleanup -> {Map.fetch!(cleanup, key), cleanup} end)
  end

  defp build_parent_index(cleanup_states) do
    cleanup_states
    |> Enum.reject(&is_nil(&1.parent_call_id))
    |> Enum.group_by(& &1.parent_call_id)
    |> Map.new(fn {parent_call_id, states} ->
      {parent_call_id, Enum.sort_by(states, & &1.first_event_seq)}
    end)
  end

  defp fetch(index, key) do
    case Map.fetch(index, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end
end
