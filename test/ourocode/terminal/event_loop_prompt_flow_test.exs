defmodule Ourocode.Terminal.EventLoopPromptFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoopPromptFlow

  test "accept_input_event buffers accepted input and appends steering to target pane" do
    input_event = %{
      event_seq: 4,
      task_request_id: "task-1",
      task_input: "Inspect child",
      steering_target: :child,
      steering_target_pane_id: "pane-child-1",
      steering_target_session_id: "session-child-1",
      steering_target_kind: :child_session,
      steering_text: "Inspect child",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "pane-child-1",
        target_session_id: "session-child-1",
        target_kind: :child_session,
        content: "Inspect child"
      },
      occurred_at_ms: 123
    }

    state = %{
      accepted_input_buffer: [],
      pane_model: %{
        panes: %{
          child: %{
            id: "pane-child-1",
            kind: :child_session,
            pane_state: %{stream_entries: []}
          }
        }
      }
    }

    updated = EventLoopPromptFlow.accept_input_event(state, input_event)

    assert updated.accepted_input_buffer == [input_event]

    assert get_in(updated.pane_model, [:panes, :child, :pane_state, :stream_entries]) == [
             %{
               type: :pane_directed_steering_message,
               event_seq: 4,
               task_request_id: "task-1",
               content: "Inspect child",
               target_pane_id: "pane-child-1",
               target_session_id: "session-child-1",
               target_kind: :child_session,
               payload: input_event.steering_message,
               occurred_at_ms: 123
             }
           ]
  end

  test "transition_state records prompt state events and invokes callback" do
    parent = self()
    input_event = %{task_request_id: "task-2"}

    state = %{
      startup_result: %{status: :healthy},
      prompt_state: :awaiting_prompt,
      prompt_state_events: [],
      on_prompt_state_change: fn state_event, startup_result ->
        send(parent, {:prompt_state_changed, state_event, startup_result})
      end
    }

    updated = EventLoopPromptFlow.transition_state(state, :dispatching_input, input_event)

    assert updated.prompt_state == :dispatching_input

    assert [%{prompt_state: :dispatching_input, task_request_id: "task-2"} = event] =
             updated.prompt_state_events

    assert_receive {:prompt_state_changed, ^event, %{status: :healthy}}
  end
end
