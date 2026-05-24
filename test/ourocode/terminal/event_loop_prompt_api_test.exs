defmodule Ourocode.Terminal.EventLoopPromptApiTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.EventLoop

  test "normalize_input_line builds natural-language prompt events without command syntax" do
    assert {:ok,
            {task_request,
             %{
               type: :prompt_input_submitted,
               source: :terminal_prompt,
               input_kind: :natural_language,
               task_input: "Compare stdio and SSE event streams",
               routing_decision: %{requires_command_syntax?: false}
             }}} =
             EventLoop.normalize_input_line(" Compare stdio\nand SSE event streams ",
               id: "prompt-input-test",
               submitted_at_ms: 1_234
             )

    assert task_request.id == "prompt-input-test"
    assert task_request.task_input == "Compare stdio and SSE event streams"
  end

  test "dispatch_prompt_input_event rebuilds task request from normalized event" do
    assert {:ok, {_task_request, input_event}} =
             EventLoop.normalize_input_line("Investigate prompt processing",
               id: "normalized-event-task",
               submitted_at_ms: 88
             )

    parent = self()

    assert {:ok, dispatched_task_request} =
             EventLoop.dispatch_prompt_input_event(input_event, %{status: :healthy},
               on_prompt_input: fn task_request, event, startup_result ->
                 send(parent, {:prompt_processed, task_request, event, startup_result})
               end
             )

    assert dispatched_task_request.id == "normalized-event-task"
    assert dispatched_task_request.task_input == "Investigate prompt processing"

    assert_receive {:prompt_processed, ^dispatched_task_request, ^input_event,
                    %{status: :healthy}}
  end

  test "dispatch_prompt_input_event rejects non natural-language events" do
    assert EventLoop.dispatch_prompt_input_event(
             %{type: :slash_command_submitted, input_kind: :slash_command},
             %{status: :healthy}
           ) == {:error, {:unsupported_input_kind, :slash_command}}
  end
end
