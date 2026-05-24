defmodule Ourocode.Runtime.Stream.MailboxFlushTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.MailboxFlush

  test "marks stream-completed flushes with the current cursor" do
    state =
      state()
      |> Map.put(:stream_cursor, %{event_seq: 7})
      |> MailboxFlush.mark_completed(:stream_completed)

    assert state.stream_completion_status == :completed
    assert state.stream_completion_cursor == %{event_seq: 7}
  end

  test "leaves non-completion flush reasons unchanged" do
    state =
      state()
      |> Map.put(:stream_completion_status, :streaming)
      |> Map.put(:stream_completion_cursor, nil)
      |> MailboxFlush.mark_completed(:release)

    assert state.stream_completion_status == :streaming
    assert is_nil(state.stream_completion_cursor)
  end

  test "builds final flush payload from completed mailbox state" do
    flush =
      state()
      |> Map.merge(%{
        stream_kind: :child,
        runtime_source: "synthetic",
        transport: :sse,
        parent_call_id: "parent-1",
        child_id: "child-1",
        session_id: "session-1",
        external_ids: %{"job_id" => "job-1"},
        stream_cursor: %{event_seq: 3},
        stream_mailbox_pending_count: 0,
        stream_mailbox_final_flush_count: 2,
        stream_completion_status: :completed,
        stream_completion_cursor: %{event_seq: 3}
      })
      |> MailboxFlush.payload(:stream_completed, 2, [3, 2])

    assert flush == %{
             reason: :stream_completed,
             stream_kind: :child,
             runtime_source: "synthetic",
             transport: :sse,
             parent_call_id: "parent-1",
             child_id: "child-1",
             session_id: "session-1",
             external_ids: %{"job_id" => "job-1"},
             stream_cursor: %{event_seq: 3},
             flushed_pending_count: 2,
             rendered_event_seqs: [2, 3],
             pending_count: 0,
             final_flush_count: 2,
             completion_status: :completed,
             completion_cursor: %{event_seq: 3}
           }
  end

  defp state do
    %{
      stream_kind: :session,
      stream_cursor: %{},
      stream_mailbox_pending_count: 0,
      stream_mailbox_final_flush_count: 0,
      stream_completion_status: :streaming,
      stream_completion_cursor: nil
    }
  end
end
