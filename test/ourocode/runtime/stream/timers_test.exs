defmodule Ourocode.Runtime.Stream.TimersTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.Timers

  test "schedule_idle sends the lifecycle idle timeout message" do
    ref = Timers.schedule_idle(1, 123)

    assert is_reference(ref)
    assert_receive {:stream_idle_timeout, 123}, 50
  end

  test "schedule_operation sends the lifecycle operation timeout message" do
    ref = Timers.schedule_operation(1, "op-1", 456)

    assert is_reference(ref)
    assert_receive {:stream_operation_timeout, "op-1", 456}, 50
  end

  test "cancel_idle and cancel_operation preserve state and suppress messages" do
    idle_ref = Timers.schedule_idle(50, 111)
    operation_ref = Timers.schedule_operation(50, "op-2", 222)

    state = %{
      stream_idle_timer_ref: idle_ref,
      stream_operation_timer_ref: operation_ref
    }

    assert Timers.cancel_idle(state) == state
    assert Timers.cancel_operation(state) == state

    refute_receive {:stream_idle_timeout, 111}, 80
    refute_receive {:stream_operation_timeout, "op-2", 222}, 0
  end

  test "cancel helpers tolerate missing timers" do
    state = %{stream_idle_timer_ref: nil, stream_operation_timer_ref: nil}

    assert Timers.cancel_idle(state) == state
    assert Timers.cancel_operation(state) == state
  end
end
