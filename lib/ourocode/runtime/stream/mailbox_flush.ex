defmodule Ourocode.Runtime.Stream.MailboxFlush do
  @moduledoc """
  Final flush completion state and event payload construction.
  """

  @type final_flush :: Ourocode.Runtime.Stream.Mailbox.final_flush()

  @spec mark_completed(map(), atom()) :: map()
  def mark_completed(state, :stream_completed) do
    state
    |> Map.put(:stream_completion_status, :completed)
    |> Map.put(:stream_completion_cursor, Map.get(state, :stream_cursor, %{}))
  end

  def mark_completed(state, _reason), do: state

  @spec payload(map(), atom(), non_neg_integer(), [term()]) :: final_flush()
  def payload(state, reason, flushed_pending_count, rendered_event_seqs) do
    %{
      reason: reason,
      stream_kind: state.stream_kind,
      runtime_source: Map.get(state, :runtime_source),
      transport: Map.get(state, :transport),
      parent_call_id: Map.get(state, :parent_call_id),
      child_id: Map.get(state, :child_id),
      session_id: Map.get(state, :session_id),
      external_ids: Map.get(state, :external_ids, %{}),
      stream_cursor: Map.get(state, :stream_cursor, %{}),
      flushed_pending_count: flushed_pending_count,
      rendered_event_seqs: Enum.reverse(rendered_event_seqs),
      pending_count: Map.get(state, :stream_mailbox_pending_count, 0),
      final_flush_count: state.stream_mailbox_final_flush_count,
      completion_status: state.stream_completion_status,
      completion_cursor: state.stream_completion_cursor
    }
  end
end
