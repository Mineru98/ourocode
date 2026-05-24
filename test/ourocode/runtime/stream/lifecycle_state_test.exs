defmodule Ourocode.Runtime.Stream.LifecycleStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Config
  alias Ourocode.Runtime.Stream.LifecycleState

  test "builds default lifecycle state from config defaults" do
    config = Config.defaults()
    state = LifecycleState.fields([], 123)

    assert state.stream_status == :active
    assert state.stream_last_activity_monotonic_ms == 123
    assert state.stream_stale_cleanup_timeout_ms == config.stale_cleanup_timeout_ms

    assert state.stream_subscription_cleanup_timeout_ms ==
             config.stream_subscription_cleanup_timeout_ms

    assert state.stream_operation_timeout_ms == config.operation_timeout_ms
    assert state.stream_cleanup_action == :stop
    assert state.stream_process_handles == []
    assert state.stream_subscriptions == []
    assert state.stream_registered_buffers == []
    assert state.stream_operation_timeout_count == 0
    assert is_nil(state.stream_active_operation_timeout_ms)
    assert is_nil(state.stream_active_operation_id)
    assert is_nil(state.stream_operation_started_monotonic_ms)
    assert is_nil(state.stream_operation_deadline_monotonic_ms)
    assert is_nil(state.stream_operation_timer_ref)
    assert is_nil(state.stream_cleanup_started_monotonic_ms)
    assert is_nil(state.stream_cleanup_reason)
    assert is_reference(state.stream_idle_timer_ref)
  end

  test "honors lifecycle option overrides and schedules idle timeout with fixed timestamp" do
    lifecycle_target = self()
    operation_timeout_target = self()
    cleanup_target = self()

    state =
      LifecycleState.fields(
        [
          stale_cleanup_timeout_ms: 1,
          stream_subscription_cleanup_timeout_ms: 2,
          operation_timeout_ms: 3,
          stream_lifecycle_target: lifecycle_target,
          stream_operation_timeout_target: operation_timeout_target,
          stream_cleanup_target: cleanup_target,
          stream_cleanup_action: :mark_stale,
          stream_process_handles: [:port],
          stream_subscriptions: [:subscription],
          stream_registered_buffers: [:buffer]
        ],
        456
      )

    assert state.stream_stale_cleanup_timeout_ms == 1
    assert state.stream_subscription_cleanup_timeout_ms == 2
    assert state.stream_operation_timeout_ms == 3
    assert state.stream_lifecycle_target == lifecycle_target
    assert state.stream_operation_timeout_target == operation_timeout_target
    assert state.stream_cleanup_target == cleanup_target
    assert state.stream_cleanup_action == :mark_stale
    assert state.stream_process_handles == [:port]
    assert state.stream_subscriptions == [:subscription]
    assert state.stream_registered_buffers == [:buffer]
    assert_receive {:stream_idle_timeout, 456}, 50
  end
end
