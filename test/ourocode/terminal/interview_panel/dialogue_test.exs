defmodule Ourocode.Terminal.InterviewPanel.DialogueTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Dialogue

  test "formats visible dialogue turns with role styles and separators" do
    state = %{
      dialogue: [
        %{role: :mcp, text: "Second question"},
        %{role: :user, text: "First answer"}
      ]
    }

    assert Dialogue.rows(state, false) == [
             {"YOU   First answer", :strong},
             :rule,
             {"MCP   Second question", :warn}
           ]
  end

  test "drops trailing MCP turn when requested" do
    state = %{
      dialogue: [
        %{role: :mcp, text: "Follow-up pending"},
        %{role: :user, text: "Known answer"}
      ]
    }

    assert Dialogue.rows(state, true) == [{"YOU   Known answer", :strong}]
  end

  test "filters leaked internal router prompts from main dialogue" do
    state = %{
      dialogue: [
        %{role: :user, text: "Visible"},
        %{role: :main, text: "You are the answerer/router half\nTool protocol"}
      ]
    }

    assert Dialogue.rows(state, false) == [{"YOU   Visible", :strong}]
  end

  test "keeps only the most recent dialogue turns from newest-first state" do
    state = %{
      dialogue:
        Enum.map(1..8, fn index ->
          %{role: :user, text: "Turn #{index}"}
        end)
    }

    assert Dialogue.rows(state, false) == [
             {"YOU   Turn 6", :strong},
             :rule,
             {"YOU   Turn 5", :strong},
             :rule,
             {"YOU   Turn 4", :strong},
             :rule,
             {"YOU   Turn 3", :strong},
             :rule,
             {"YOU   Turn 2", :strong},
             :rule,
             {"YOU   Turn 1", :strong}
           ]
  end
end
