defmodule Ourocode.Terminal.ParentWorkflowFeedbackTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{EventLoop, ParentWorkflowFeedback}

  test "renders accepted prompt and workflow-start state for the parent pane" do
    prompt = "ooo interview로 terminal feedback 요구사항을 정리해줘."

    assert {:ok, {_task_request, input_event}} =
             EventLoop.normalize_input_line(prompt,
               id: "feedback-task-1",
               submitted_at_ms: 123
             )

    state_event = %{
      type: :prompt_loop_state_changed,
      event_type: :prompt_loop_state_changed,
      source: :terminal_prompt,
      prompt_state: :dispatching_input,
      reason: :input_dispatch_started,
      task_request_id: "feedback-task-1",
      occurred_at_ms: 124
    }

    feedback = ParentWorkflowFeedback.render(input_event, state_event)
    frame = ParentWorkflowFeedback.render_text(feedback)

    assert feedback == %{
             kind: :terminal_parent_workflow_feedback,
             region: :parent_pane,
             status: :workflow_starting,
             task_request_id: "feedback-task-1",
             accepted_prompt: prompt,
             workflow_route: :ouroboros_workflow,
             adapter_route: :interview,
             prompt_state: :dispatching_input,
             line:
               ~s([workflow-starting] state=dispatching_input task=feedback-task-1 route=ouroboros_workflow adapter=interview accepted_prompt="#{prompt}")
           }

    assert frame ==
             Enum.join(
               [
                 "+-- Parent Workflow region=parent_pane",
                 ~s(| [workflow-starting] state=dispatching_input task=feedback-task-1 route=ouroboros_workflow adapter=interview accepted_prompt="#{prompt}"),
                 "+--"
               ],
               "\n"
             )
  end
end
