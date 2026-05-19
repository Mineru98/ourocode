defmodule Ourocode.Journal.RelationshipRecoveryRecord do
  @moduledoc """
  Typed recovery record for persisted parent-call to child-session mappings.

  External runtime identifiers and statuses remain trusted source data. The
  record keeps only the local recovery view needed to rebuild pane mappings,
  cursors, and relationship state after loading the journal.
  """

  @enforce_keys [
    :event_seq,
    :event_type,
    :parent_call_id,
    :child_id,
    :pane_id,
    :runtime_source,
    :transport,
    :external_ids,
    :stream_cursor,
    :pane_state,
    :occurred_at_ms
  ]
  defstruct [
    :event_seq,
    :event_type,
    :parent_call_id,
    :child_id,
    :pane_id,
    :runtime_source,
    :transport,
    :external_ids,
    :stream_cursor,
    :acknowledged_stream_cursor,
    :pane_state,
    :occurred_at_ms,
    :created_at_ms,
    :updated_at_ms,
    :status,
    :child_id_source,
    :payload_path,
    :source_event
  ]

  @type transport :: :stdio | :streamable_http | :sse

  @type t :: %__MODULE__{
          event_seq: non_neg_integer(),
          event_type: atom(),
          parent_call_id: String.t(),
          child_id: String.t(),
          pane_id: String.t(),
          runtime_source: String.t(),
          transport: transport(),
          external_ids: map(),
          stream_cursor: map(),
          acknowledged_stream_cursor: map() | nil,
          pane_state: map(),
          occurred_at_ms: integer(),
          created_at_ms: integer() | nil,
          updated_at_ms: integer() | nil,
          status: atom() | nil,
          child_id_source: atom() | tuple() | nil,
          payload_path: atom() | nil,
          source_event: map()
        }
end
