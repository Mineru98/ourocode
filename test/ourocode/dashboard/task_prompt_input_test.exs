defmodule Ourocode.Dashboard.TaskPromptInputTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.TaskPromptInput

  test "renders a ready natural-language task prompt" do
    assert TaskPromptInput.render() == %{
             id: :task_prompt,
             kind: :natural_language_task_input,
             title: "Task",
             placeholder: "Describe a task for a new session",
             value: "",
             cursor_position: 0,
             focused?: true,
             editable?: true,
             representative_ux: :natural_language_task_input,
             submit_action: :start_session
           }
  end

  test "keeps the product representative prompt in natural-language task mode" do
    prompt = TaskPromptInput.render()

    assert prompt.representative_ux == :natural_language_task_input
    assert prompt.placeholder == "Describe a task for a new session"
    refute String.contains?(String.downcase(prompt.placeholder), "command")
    refute String.contains?(String.downcase(prompt.placeholder), "diagnostic")
  end

  test "formats empty and filled prompt lines for terminal renderers" do
    assert TaskPromptInput.render_line(TaskPromptInput.render()) ==
             "> Describe a task for a new session"

    assert TaskPromptInput.render_line(TaskPromptInput.render(value: "Investigate MCP stream loss")) ==
             "> Investigate MCP stream loss"
  end

  test "clamps cursor position to the entered task text" do
    assert %{cursor_position: 4} = TaskPromptInput.render(value: "Task", cursor_position: 99)
    assert %{cursor_position: 0} = TaskPromptInput.render(value: "Task", cursor_position: -1)
  end

  test "submits prompt value as a natural-language task request" do
    prompt = TaskPromptInput.render(value: "Investigate child session panes")

    assert {:ok,
            %Ourocode.TaskRequest{
              source: :dashboard,
              task_input: "Investigate child session panes",
              routing_decision: %{requires_command_syntax?: false}
            }} =
             TaskPromptInput.submit(prompt, id: "prompt-task", submitted_at_ms: 303)
  end
end
