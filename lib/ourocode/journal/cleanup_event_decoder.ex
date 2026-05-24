defmodule Ourocode.Journal.CleanupEventDecoder do
  @moduledoc """
  Decodes journal entries into cleanup recovery records.

  Cleanup events prove runtime resources were released. Completed child pane
  events are also decoded so restart recovery can keep completed session cleanup
  state even when pane retention outlives the runtime stream process. Failed
  lifecycle events are decoded as pending cleanup records so restart recovery
  can prove a later cleanup action made the replay idempotent.
  """

  alias Ourocode.Journal.CleanupEventFields, as: Fields
  alias Ourocode.Journal.CleanupEventType
  alias Ourocode.Journal.CleanupRecoveryRecord
  alias Ourocode.Journal.CleanupState

  @type decode_result :: {:ok, CleanupRecoveryRecord.t()} | :ignore | {:error, term()}

  @spec decode_all([map()]) :: {:ok, [CleanupRecoveryRecord.t()]} | {:error, term()}
  def decode_all(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case decode(entry) do
        {:ok, record} -> {:cont, {:ok, [record | acc]}}
        :ignore -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec decode(map()) :: decode_result()
  def decode(event) when is_map(event) do
    event = Fields.normalize(event)

    case CleanupEventType.category(event) do
      {:ok, :cleanup, event_type} -> decode_cleanup_event(event, event_type)
      {:ok, :orphan_candidate, event_type} -> decode_orphan_candidate_event(event, event_type)
      {:ok, :completion, event_type} -> decode_completion_event(event, event_type)
      {:ok, :failure, event_type} -> decode_failure_event(event, event_type)
      :error -> :ignore
    end
  end

  def decode(_event), do: :ignore

  defp decode_cleanup_event(event, event_type) do
    with {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- CleanupState.cleanup_key(event, :prefer_child) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :completed,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :noop
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp decode_orphan_candidate_event(event, event_type) do
    with {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- CleanupState.cleanup_key(event, :prefer_session) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :pending,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :release_runtime_resources
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp decode_completion_event(event, event_type) do
    with {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- CleanupState.cleanup_key(event, :prefer_child) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :completed,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :noop
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp decode_failure_event(event, event_type) do
    with {:ok, event_seq} <- required_integer(event, :event_seq),
         {:ok, runtime_source} <- required_string(event, :runtime_source),
         {:ok, occurred_at_ms} <- occurred_at_ms(event),
         {:ok, cleanup_key} <- CleanupState.cleanup_key(event, :prefer_child) do
      {:ok,
       recovery_record(event, %{
         event_seq: event_seq,
         event_type: event_type,
         cleanup_key: cleanup_key,
         cleanup_state: :pending,
         runtime_source: runtime_source,
         occurred_at_ms: occurred_at_ms,
         replay_action: :release_runtime_resources
       })}
    else
      reason -> {:error, {:invalid_cleanup_journal_event, reason, event}}
    end
  end

  defp recovery_record(event, attrs) do
    %CleanupRecoveryRecord{
      event_seq: attrs.event_seq,
      event_type: attrs.event_type,
      cleanup_key: attrs.cleanup_key,
      cleanup_state: attrs.cleanup_state,
      cleanup_reason: Fields.atom_value(event, :cleanup_reason),
      stream_kind: Fields.atom_value(event, :stream_kind),
      parent_call_id: Fields.string_value(event, :parent_call_id),
      child_id: Fields.string_value(event, :child_id),
      session_id: Fields.session_id(event),
      pane_id: Fields.string_value(event, :pane_id),
      runtime_source: attrs.runtime_source,
      transport: Fields.transport(event),
      external_ids: Fields.map_value(event, :external_ids, %{}),
      stream_cursor: Fields.map_value(event, :stream_cursor, %{}),
      pane_state: Fields.map_value(event, :pane_state, %{}),
      released_resources: Fields.map_value(event, :released_resources, %{}),
      stale_cleanup_timeout_ms: Fields.integer_value(event, :stale_cleanup_timeout_ms),
      stream_subscription_cleanup_timeout_ms:
        Fields.integer_value(event, :stream_subscription_cleanup_timeout_ms),
      cleanup_started_monotonic_ms: Fields.integer_value(event, :cleanup_started_monotonic_ms),
      idempotency_key: CleanupState.idempotency_key(event, attrs.cleanup_key),
      replay_action: CleanupState.replay_action(event, attrs.replay_action),
      occurred_at_ms: attrs.occurred_at_ms,
      source_event: event
    }
  end

  defp required_string(event, key) do
    case Fields.string_value(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing_required_string, key}}
    end
  end

  defp required_integer(event, key) do
    case Fields.integer_value(event, key) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required_integer, key}}
    end
  end

  defp occurred_at_ms(event) do
    case Fields.integer_value(event, :occurred_at_ms) ||
           Fields.integer_value(event, :updated_at_ms) ||
           Fields.integer_value(event, :created_at_ms) do
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, {:missing_required_integer, :occurred_at_ms}}
    end
  end
end
