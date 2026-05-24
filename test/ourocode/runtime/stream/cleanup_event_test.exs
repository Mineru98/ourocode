defmodule Ourocode.Runtime.Stream.CleanupEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.CleanupEvent

  test "idle_timeout builds cleanup payload with shared stream identity" do
    cleanup = CleanupEvent.idle_timeout(state(), 1_500, 500, released_resources())

    assert cleanup.cleanup_reason == :idle_timeout
    assert cleanup.stream_kind == :child
    assert cleanup.runtime_source == "runtime"
    assert cleanup.transport == :sse
    assert cleanup.parent_call_id == "parent-1"
    assert cleanup.child_id == "child-1"
    assert cleanup.idle_elapsed_ms == 500
    assert cleanup.last_activity_monotonic_ms == 1_000
    assert cleanup.cleanup_started_monotonic_ms == 1_500
    assert cleanup.released_resources == released_resources()
  end

  test "operation_timeout includes active operation metadata" do
    cleanup = CleanupEvent.operation_timeout(state(), 2_000, 700, released_resources())

    assert cleanup.cleanup_reason == :operation_timeout
    assert cleanup.operation_id == "op-1"
    assert cleanup.operation_elapsed_ms == 700
    assert cleanup.operation_timeout_ms == 1_200
    assert cleanup.operation_started_monotonic_ms == 1_100
  end

  test "timeout_termination marks cleanup as stream terminated" do
    assert CleanupEvent.timeout_termination(%{cleanup_reason: :idle_timeout}) == %{
             cleanup_reason: :idle_timeout,
             lifecycle_type: :stream_terminated,
             exit_state: :normal,
             exit_reason: :idle_timeout
           }
  end

  defp state do
    %{
      stream_kind: :child,
      runtime_source: "runtime",
      transport: :sse,
      parent_call_id: "parent-1",
      child_id: "child-1",
      session_id: "session-1",
      external_ids: %{"session_id" => "session-1"},
      stream_cursor: %{event_seq: 9},
      stream_stale_cleanup_timeout_ms: 30_000,
      stream_subscription_cleanup_timeout_ms: 10_000,
      stream_last_activity_monotonic_ms: 1_000,
      stream_active_operation_id: "op-1",
      stream_active_operation_timeout_ms: 1_200,
      stream_operation_timeout_ms: 5_000,
      stream_operation_started_monotonic_ms: 1_100
    }
  end

  defp released_resources do
    %{
      process_handles: 0,
      subscriptions: 1,
      registered_buffers: 0,
      ets_entries: 0,
      pending_events: 2
    }
  end
end
