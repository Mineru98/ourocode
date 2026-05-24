defmodule Ourocode.Runtime.Stream.Timers do
  @moduledoc """
  Timer scheduling and cancellation helpers for runtime stream lifecycle.
  """

  @spec cancel_idle(map()) :: map()
  def cancel_idle(%{stream_idle_timer_ref: nil} = state), do: state

  def cancel_idle(%{stream_idle_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    state
  end

  @spec cancel_operation(map()) :: map()
  def cancel_operation(%{stream_operation_timer_ref: nil} = state), do: state

  def cancel_operation(%{stream_operation_timer_ref: timer_ref} = state) do
    Process.cancel_timer(timer_ref)
    state
  end

  @spec schedule_idle(pos_integer(), integer()) :: reference()
  def schedule_idle(timeout_ms, last_activity_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Process.send_after(self(), {:stream_idle_timeout, last_activity_ms}, timeout_ms)
  end

  @spec schedule_operation(pos_integer(), term(), integer()) :: reference()
  def schedule_operation(timeout_ms, operation_id, deadline_ms)
      when is_integer(timeout_ms) and timeout_ms > 0 do
    Process.send_after(self(), {:stream_operation_timeout, operation_id, deadline_ms}, timeout_ms)
  end
end
