defmodule Ourocode.Runtime.Stream.MailboxStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Config
  alias Ourocode.Runtime.Stream.MailboxState

  test "builds default mailbox state from config defaults" do
    config = Config.defaults()
    state = MailboxState.fields([])

    assert state.stream_mailbox_capacity == config.stream_mailbox_capacity
    assert state.stream_mailbox_overflow_path == config.stream_mailbox_overflow_path

    assert state.stream_mailbox_backpressure_threshold ==
             config.stream_mailbox_backpressure_threshold

    assert state.stream_mailbox_backpressure_behavior ==
             config.stream_mailbox_backpressure_behavior

    assert state.stream_mailbox_backpressure_delay_ms ==
             config.stream_mailbox_backpressure_delay_ms

    assert state.stream_mailbox_pending == :queue.new()
    assert state.stream_mailbox_pending_count == 0
    assert state.stream_mailbox_overflow_count == 0
    assert state.stream_mailbox_backpressure_count == 0
    refute state.stream_mailbox_backpressure_active?
    refute state.stream_mailbox_draining?
    assert state.stream_mailbox_drain_interval_ms == 0
    assert state.stream_completion_status == :streaming
    assert is_nil(state.stream_completion_cursor)
  end

  test "honors mailbox option overrides and targets" do
    overflow_target = self()
    backpressure_target = self()
    final_flush_target = self()
    rendered_event_target = self()
    subscribers = [self()]

    state =
      MailboxState.fields(
        stream_mailbox_capacity: 12,
        stream_mailbox_overflow_path: :notify,
        stream_mailbox_overflow_target: overflow_target,
        stream_mailbox_backpressure_threshold: 4,
        stream_mailbox_backpressure_behavior: :delay,
        stream_mailbox_backpressure_target: backpressure_target,
        stream_mailbox_backpressure_delay_ms: 25,
        stream_mailbox_final_flush_target: final_flush_target,
        stream_mailbox_rendered_event_target: rendered_event_target,
        stream_event_subscribers: subscribers,
        stream_mailbox_drain_interval_ms: :manual
      )

    assert state.stream_mailbox_capacity == 12
    assert state.stream_mailbox_overflow_path == :notify
    assert state.stream_mailbox_overflow_target == overflow_target
    assert state.stream_mailbox_backpressure_threshold == 4
    assert state.stream_mailbox_backpressure_behavior == :delay
    assert state.stream_mailbox_backpressure_target == backpressure_target
    assert state.stream_mailbox_backpressure_delay_ms == 25
    assert state.stream_mailbox_final_flush_target == final_flush_target
    assert state.stream_mailbox_rendered_event_target == rendered_event_target
    assert state.stream_event_subscribers == subscribers
    assert state.stream_mailbox_drain_interval_ms == :manual
  end
end
