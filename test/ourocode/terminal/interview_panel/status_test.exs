defmodule Ourocode.Terminal.InterviewPanel.StatusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Status

  test "working_line sanitizes router protocol traces" do
    assert Status.working_line(0, "ASK_USER (4 opt): What should change next?") ==
             "| question ready — choose or type an answer in the interview block"

    assert Status.working_line(1, "ANSWER [code]: Elixir project") ==
             "/ main session answered: Elixir project"

    assert Status.working_line(2, "TOOL READ mix.exs") ==
             "- main session is checking project context"
  end

  test "reasoning_lines prefers MCP-provided reasoning over fallback facts" do
    iv = %{
      ambiguity: 0.31,
      milestone: "scope",
      seed_ready: false,
      mcp_reasoning: ["phase: answer", "  ", "next: ask user"]
    }

    assert Status.reasoning_lines(iv, nil, false) == ["phase: answer", "next: ask user"]
  end

  test "reasoning_lines formats fallback facts and waiting status" do
    iv = %{
      waiting: true,
      status: "waiting for MCP follow-up question",
      ambiguity: 0.42,
      milestone: "scope",
      seed_ready: true,
      session_id: "iv-1",
      complete: :seed_ready
    }

    assert Status.reasoning_lines(iv, 1, false) == [
             "/ phase routing - MCP is preparing the next question",
             "session iv-1",
             "ambiguity 0.42",
             "milestone scope",
             "seed-ready: yes",
             "interview complete: seed_ready"
           ]
  end

  test "mcp_activity_lines normalizes prefixes and caps the tail" do
    lines = [""] ++ Enum.map(1..85, &"round #{&1}")

    activity = Status.mcp_activity_lines(lines)

    assert length(activity) == 80
    assert hd(activity) == "activity: round 6"
    assert List.last(activity) == "activity: round 85"
  end
end
