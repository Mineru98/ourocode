defmodule Ourocode.Runtime.Stream.MailboxPressureTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.MailboxPressure

  test "builds drop-newest overflow payload from mailbox state and event" do
    assert MailboxPressure.overflow(state(), %{event_seq: 9}) == %{
             overflow_path: :notify,
             overflow_behavior: :drop_newest,
             stream_kind: :child,
             event_seq: 9,
             dropped_event_seq: 9,
             capacity: 4,
             retained_pending_count: 4
           }
  end

  test "detects backpressure only when enabled and over threshold" do
    refute MailboxPressure.backpressure?(%{state() | stream_mailbox_backpressure_behavior: :none})
    refute MailboxPressure.backpressure?(%{state() | stream_mailbox_pending_count: 1})
    assert MailboxPressure.backpressure?(%{state() | stream_mailbox_pending_count: 2})
  end

  test "builds backpressure payload including delay policy" do
    pressure =
      state()
      |> Map.merge(%{
        stream_mailbox_backpressure_behavior: :delay,
        stream_mailbox_backpressure_delay_ms: 25
      })
      |> MailboxPressure.backpressure(%{event_seq: 10})

    assert pressure == %{
             backpressure_behavior: :delay,
             stream_kind: :child,
             event_seq: 10,
             threshold: 2,
             capacity: 4,
             pending_count: 4,
             delay_ms: 25
           }
  end

  test "builds relief payloads for drain and release paths" do
    drained_state = %{state() | stream_mailbox_pending_count: 1}

    assert MailboxPressure.relief(drained_state, %{event_seq: 7}, 2) == %{
             backpressure_behavior: :notify,
             stream_kind: :child,
             event_seq: 7,
             threshold: 2,
             capacity: 4,
             pending_count: 1,
             previous_pending_count: 2,
             delay_ms: 0
           }

    assert MailboxPressure.release_relief(state(), 4) == %{
             backpressure_behavior: :notify,
             stream_kind: :child,
             event_seq: 6,
             threshold: 2,
             capacity: 4,
             pending_count: 0,
             previous_pending_count: 4,
             delay_ms: 0
           }
  end

  defp state do
    %{
      stream_kind: :child,
      stream_cursor: %{event_seq: 6},
      stream_mailbox_capacity: 4,
      stream_mailbox_pending_count: 4,
      stream_mailbox_overflow_path: :notify,
      stream_mailbox_backpressure_threshold: 2,
      stream_mailbox_backpressure_behavior: :notify,
      stream_mailbox_backpressure_delay_ms: 0
    }
  end
end
