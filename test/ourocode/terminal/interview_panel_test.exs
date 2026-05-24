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

  test "interview block falls back to the active question when wonder request is incomplete" do
    result = %{
      wonder_tool: %{request_id: "bad-wt", request: %{"questions" => []}},
      interview: %{question: "지금 어느 범위를 먼저 볼까요?", status: "waiting for your answer"}
    }

    assert {"INTERVIEW", lines, "type your answer + Enter   Esc pause"} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert {"지금 어느 범위를 먼저 볼까요?", :warn} in lines
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

  test "interview block renders stored question options as a picker" do
    result = %{
      interview: %{
        question: "Which first user outcome matters most?",
        question_options: [
          %{label: "Quality", description: "Raise reliability first"},
          %{label: "Speed", description: "Optimize turnaround first"}
        ],
        status: "waiting for your answer"
      }
    }

    assert {"INTERVIEW", lines, "type your answer + Enter   Esc pause"} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert "Interview" in lines
    assert "Which first user outcome matters most?" in lines
    assert ">> [1] Quality - Raise reliability first" in lines
    assert "   [2] Speed - Optimize turnaround first" in lines

    refute Enum.any?(lines, fn
             {line, _style} -> line =~ "question ready"
             line when is_binary(line) -> line =~ "question ready"
             :rule -> false
           end)
  end

  test "interview block fails closed to the current question when dialogue is malformed" do
    result = %{
      interview: %{
        dialogue: [:malformed_turn],
        question: "Which first user outcome should this interview clarify?",
        status: "waiting for your answer"
      }
    }

    assert {"INTERVIEW", lines, "type your answer + Enter   Esc pause"} =
             InterviewPanel.interview_block_lines(result, nil, 0)

    assert {"Which first user outcome should this interview clarify?", :warn} in lines
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
