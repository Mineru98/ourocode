defmodule Ourocode.Journal.CleanupRecoveryRecord do
  @moduledoc """
  Typed recovery record for persisted cleanup state.

  External runtime IDs and status are preserved as source data. The record keeps
  the local cleanup replay facts ourocode owns after restart: the stable cleanup
  key, cursor, pane state, released resources, and whether replay should be a
  no-op because cleanup already completed.
  """

  @enforce_keys [
    :event_seq,
    :event_type,
    :cleanup_key,
    :cleanup_state,
    :runtime_source,
    :external_ids,
    :stream_cursor,
    :released_resources,
    :idempotency_key,
    :replay_action,
    :occurred_at_ms
  ]
  defstruct [
    :event_seq,
    :event_type,
    :cleanup_key,
    :cleanup_state,
    :cleanup_reason,
    :stream_kind,
    :parent_call_id,
    :child_id,
    :session_id,
    :pane_id,
    :runtime_source,
    :transport,
    :external_ids,
    :stream_cursor,
    :pane_state,
    :released_resources,
    :stale_cleanup_timeout_ms,
    :stream_subscription_cleanup_timeout_ms,
    :cleanup_started_monotonic_ms,
    :idempotency_key,
    :replay_action,
    :occurred_at_ms,
    :source_event
  ]

  @type cleanup_state :: :completed | :pending
  @type replay_action :: :noop | :release_runtime_resources

  @type t :: %__MODULE__{
          event_seq: non_neg_integer(),
          event_type: atom(),
          cleanup_key: String.t(),
          cleanup_state: cleanup_state(),
          cleanup_reason: atom() | nil,
          stream_kind: atom() | nil,
          parent_call_id: String.t() | nil,
          child_id: String.t() | nil,
          session_id: String.t() | nil,
          pane_id: String.t() | nil,
          runtime_source: String.t(),
          transport: atom() | nil,
          external_ids: map(),
          stream_cursor: map(),
          pane_state: map(),
          released_resources: map(),
          stale_cleanup_timeout_ms: non_neg_integer() | nil,
          stream_subscription_cleanup_timeout_ms: non_neg_integer() | nil,
          cleanup_started_monotonic_ms: integer() | nil,
          idempotency_key: String.t(),
          replay_action: replay_action(),
          occurred_at_ms: integer(),
          source_event: map()
        }
end
