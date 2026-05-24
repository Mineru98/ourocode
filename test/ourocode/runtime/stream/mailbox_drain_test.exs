defmodule Ourocode.Runtime.Stream.MailboxDrainTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.MailboxDrain

  test "schedules a drain when pending events are not already draining" do
    state =
      state()
      |> Map.put(:stream_mailbox_pending_count, 1)
      |> Map.put(:stream_mailbox_draining?, false)
      |> MailboxDrain.schedule()

    assert state.stream_mailbox_draining?
    assert_receive :drain_stream_mailbox
  end

  test "manual drain mode leaves pending events unscheduled" do
    state =
      state()
      |> Map.put(:stream_mailbox_drain_interval_ms, :manual)
      |> Map.put(:stream_mailbox_pending_count, 1)
      |> Map.put(:stream_mailbox_draining?, false)
      |> MailboxDrain.schedule()

    refute state.stream_mailbox_draining?
    refute_receive :drain_stream_mailbox, 10
  end

  test "empty mailbox clears the draining flag" do
    state =
      state()
      |> Map.put(:stream_mailbox_pending_count, 0)
      |> Map.put(:stream_mailbox_draining?, true)
      |> MailboxDrain.schedule()

    refute state.stream_mailbox_draining?
    refute_receive :drain_stream_mailbox, 10
  end

  test "already draining mailbox does not schedule another drain" do
    state =
      state()
      |> Map.put(:stream_mailbox_pending_count, 1)
      |> Map.put(:stream_mailbox_draining?, true)
      |> MailboxDrain.schedule()

    assert state.stream_mailbox_draining?
    refute_receive :drain_stream_mailbox, 10
  end

  defp state do
    %{
      stream_mailbox_pending_count: 0,
      stream_mailbox_draining?: false,
      stream_mailbox_drain_interval_ms: 0
    }
  end
end
