defmodule Ourocode.Terminal.EventLoopPromptStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopPromptState

  test "event builds dispatching prompt state event" do
    event = EventLoopPromptState.event(:dispatching_input, %{task_request_id: "task-1"})

    assert event.type == :prompt_loop_state_changed
    assert event.event_type == :prompt_loop_state_changed
    assert event.source == :terminal_prompt
    assert event.prompt_state == :dispatching_input
    assert event.reason == :input_dispatch_started
    assert event.task_request_id == "task-1"
    assert is_integer(event.occurred_at_ms)
  end

  test "event builds awaiting prompt state event" do
    event = EventLoopPromptState.event(:awaiting_prompt, %{task_request_id: "task-1"})

    assert event.prompt_state == :awaiting_prompt
    assert event.reason == :input_dispatch_completed
    assert event.task_request_id == "task-1"
  end
end
