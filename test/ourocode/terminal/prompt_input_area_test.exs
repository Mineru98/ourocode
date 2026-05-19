defmodule Ourocode.Terminal.PromptInputAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{Layout, SessionListPane, TaskPromptInput}
  alias Ourocode.Terminal.PromptInputArea

  test "renders the terminal-native user input prompt area" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(value: "Create a child session")
      }
      |> Layout.apply_compact_session_list_layout()

    area = PromptInputArea.render(panes.task_prompt)
    frame = PromptInputArea.render_text(area)

    assert area.kind == :terminal_prompt_input_area
    assert area.id == :task_prompt
    assert area.input_mode == :natural_language_or_slash_command
    assert area.focused? == true
    assert area.editable? == true
    assert area.layout.region == :task_prompt
    assert area.line == "> Create a child session"

    assert frame =~ "+-- Task region=task_prompt x=0 y=22 w=72 h=3"
    assert frame =~ "mode=natural_language_or_slash_command"
    assert frame =~ "| > Create a child session"
  end

  test "renders the default placeholder in the same terminal prompt area" do
    assert PromptInputArea.render_text(TaskPromptInput.render()) ==
             Enum.join(
               [
                 "+-- Task region=unknown mode=natural_language_or_slash_command",
                 "| > Describe a task for a new session",
                 "+--"
               ],
               "\n"
             )
  end
end
