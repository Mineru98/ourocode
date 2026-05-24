defmodule Ourocode.MCP.Transport.Stdio.CleanupTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Stdio.Cleanup

  test "timeout_ms reads override or falls back to defaults" do
    assert Cleanup.timeout_ms(stale_cleanup_timeout_ms: 123) == 123
    assert is_integer(Cleanup.timeout_ms([]))
  end

  test "touch updates activity timestamp and reschedules cleanup timer" do
    before_touch_ms = Cleanup.monotonic_ms()

    state = %{
      cleanup_timer_ref: nil,
      cleanup_timeout_ms: 1_000,
      last_activity_monotonic_ms: before_touch_ms - 1
    }

    touched = Cleanup.touch(state)

    assert is_reference(touched.cleanup_timer_ref)
    assert touched.last_activity_monotonic_ms >= before_touch_ms
    Process.cancel_timer(touched.cleanup_timer_ref)
  end

  test "schedule_timer is disabled for infinity" do
    assert Cleanup.schedule_timer(:infinity, 1) == nil
  end
end
