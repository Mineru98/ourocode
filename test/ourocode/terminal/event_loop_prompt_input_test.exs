defmodule Ourocode.Terminal.EventLoopPromptInputTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.FocusState
  alias Ourocode.Terminal.EventLoopPromptInput

  test "normalize_line builds a natural-language prompt event with steering metadata" do
    focus_state =
      FocusState.new()
      |> Map.put(:focused_pane, "pane-child-1")
      |> Map.put(:steering_target, :child)
      |> Map.put(:steering_target_pane_id, "pane-child-1")
      |> Map.put(:steering_target_session_id, "session-child-1")
      |> Map.put(:steering_target_kind, :child_session)

    assert {:ok, {task_request, input_event}} =
             EventLoopPromptInput.normalize_line(" Refactor the terminal loop ",
               id: "prompt-event-1",
               submitted_at_ms: 123,
               focus_state: focus_state,
               raw_input: "Refactor the terminal loop"
             )

    assert task_request.id == "prompt-event-1"
    assert input_event.task_input == "Refactor the terminal loop"
    assert input_event.focused_pane == "pane-child-1"
    assert input_event.steering_target == :child

    assert input_event.steering_message == %{
             type: :pane_directed_steering_message,
             target_pane_id: "pane-child-1",
             content: "Refactor the terminal loop",
             target_session_id: "session-child-1",
             target_kind: :child_session
           }

    assert input_event.payload.steering_message == input_event.steering_message
  end

  test "normalize_line preserves raw free-form steering text while parsing task text" do
    steering_text = " \t keep  spacing && symbols: []{}|$`'\" 한글  "

    focus_state =
      FocusState.new()
      |> Map.put(:focused_pane, "child-session:steering-exact")
      |> Map.put(:steering_target, :child)
      |> Map.put(:steering_target_pane_id, "child-session:steering-exact")
      |> Map.put(:steering_target_session_id, "steering-exact")
      |> Map.put(:steering_target_kind, :child_session)

    assert {:ok, {task_request, input_event}} =
             EventLoopPromptInput.normalize_line(steering_text,
               id: "prompt-exact-steering",
               submitted_at_ms: 456,
               focus_state: focus_state,
               raw_input: steering_text
             )

    assert task_request.task_input == "keep spacing && symbols: []{}|$`'\" 한글"
    assert input_event.task_input == task_request.task_input
    assert input_event.raw_input == steering_text
    assert input_event.steering_text == steering_text
    assert input_event.steering_target_pane_id == "child-session:steering-exact"

    assert input_event.steering_message == %{
             type: :pane_directed_steering_message,
             target_pane_id: "child-session:steering-exact",
             target_session_id: "steering-exact",
             target_kind: :child_session,
             content: steering_text
           }

    assert input_event.payload.raw_input == steering_text
    assert input_event.payload.steering_text == steering_text
    assert input_event.payload.steering_message == input_event.steering_message
  end

  test "normalize_line preserves mixed English and Korean task payloads" do
    prompt = "ooo interview로 ourocode의 MCP streamable UI 요구사항을 정리해줘."

    assert {:ok, {task_request, input_event}} =
             EventLoopPromptInput.normalize_line(prompt,
               id: "prompt-mixed-language",
               submitted_at_ms: 789
             )

    assert task_request.task_input == prompt
    assert input_event.task_input == prompt
    assert input_event.payload.task_input == prompt
  end

  test "dispatch_event validates the event and invokes the prompt processor" do
    assert {:ok, {_task_request, input_event}} =
             EventLoopPromptInput.normalize_line("Add focused tests",
               id: "prompt-dispatch-1",
               submitted_at_ms: 456
             )

    parent = self()

    assert {:ok, dispatched} =
             EventLoopPromptInput.dispatch_event(input_event, %{status: :healthy},
               on_prompt_input: fn task_request, event, startup_result ->
                 send(
                   parent,
                   {:processed, task_request.id, event.task_request_id, startup_result}
                 )
               end
             )

    assert dispatched.id == "prompt-dispatch-1"
    assert_receive {:processed, "prompt-dispatch-1", "prompt-dispatch-1", %{status: :healthy}}
  end

  test "dispatch_event rejects unsupported or malformed input events" do
    assert EventLoopPromptInput.dispatch_event(
             %{type: :slash_command_submitted, input_kind: :slash_command},
             %{}
           ) == {:error, {:unsupported_input_kind, :slash_command}}

    assert EventLoopPromptInput.dispatch_event(%{input_kind: :natural_language}, %{}) ==
             {:error, :invalid_prompt_input_event}
  end
end
