defmodule Ourocode.Terminal.EventLoopPromptState do
  @moduledoc """
  Builds prompt loop state transition events.
  """

  @spec event(:dispatching_input | :awaiting_prompt, map()) :: map()
  def event(:dispatching_input, input_event) when is_map(input_event) do
    %{
      type: :prompt_loop_state_changed,
      event_type: :prompt_loop_state_changed,
      source: :terminal_prompt,
      prompt_state: :dispatching_input,
      reason: :input_dispatch_started,
      task_request_id: input_event.task_request_id,
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  def event(:awaiting_prompt, input_event) when is_map(input_event) do
    %{
      type: :prompt_loop_state_changed,
      event_type: :prompt_loop_state_changed,
      source: :terminal_prompt,
      prompt_state: :awaiting_prompt,
      reason: :input_dispatch_completed,
      task_request_id: input_event.task_request_id,
      occurred_at_ms: System.system_time(:millisecond)
    }
  end
end
