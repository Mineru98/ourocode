defmodule Ourocode.Terminal.InterviewPanelTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel

  defp detection(questions) do
    %{
      request_id: "req-1",
      request: %{tool: :wonder_tool, type: :multiple_choice_decision, questions: questions}
    }
  end

  defp option(label, desc, recommended? \\ false) do
    %{label: label, description: desc, recommended?: recommended?}
  end

  test "interview block renders an active wonder picker with multi-question controls" do
    det =
      detection([
        %{
          header: "Scope",
          question: "Which scope should we take?",
          options: [option("small", "one module", true), option("broad", "whole app")]
        },
        %{
          header: "Evidence",
          question: "What proof is required?",
          options: [option("tests", "focused checks"), option("audit", "manual review")]
        }
      ])

    nav = %{qidx: 0, picks: %{0 => 1, 1 => 0}}

    assert {"INTERVIEW", lines, hint} =
             InterviewPanel.interview_block_lines(%{wonder_tool: det}, nav, 0)

    assert Enum.at(lines, 0) =~ "Question 1/2"
    assert ">> [2] broad - whole app" in lines

    assert hint ==
             "Up/Dn pick   Tab next question   Free answer row   Enter submit all   Esc pause"
  end

  test "interview block renders dialogue and dim working status for plain interview state" do
    result = %{
      interview: %{
        dialogue: [
          %{role: :mcp, text: "Which workflow matters most?"},
          %{role: :user, text: "Plugin dispatch"}
        ],
        router: ["TOOL grep"]
      }
    }

    assert {"INTERVIEW", lines, "type your answer + Enter   Esc pause"} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert {"MCP   Which workflow matters most?", :warn} in lines
    assert {"YOU   Plugin dispatch", :strong} in lines
    assert :rule in lines
    assert {"| main session is checking project context", :dim} in lines
  end

  test "interview block renders sticky live session hints while no question is pending" do
    running = %{
      interview_session: %{label: "ooo interview plugin dispatch"},
      paused: false
    }

    assert {"INTERVIEW", ["ooo interview plugin dispatch", {activity, :dim}], hint} =
             InterviewPanel.interview_block_lines(running, nil, 1)

    assert activity =~ "/ thinking"
    assert hint == "running   the main session is handling this   stays until it ends"

    paused = %{running | paused: true}

    assert {"INTERVIEW (paused)", ["ooo interview plugin dispatch"], paused_hint} =
             InterviewPanel.interview_block_lines(paused, nil, 1)

    assert paused_hint == "paused   type to talk to main   /answer <answer> submits to interview"
  end
end
