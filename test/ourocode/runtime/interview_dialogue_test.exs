defmodule Ourocode.Runtime.InterviewDialogueTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewDialogue

  test "add_dialogue trims text, skips blanks, deduplicates latest turn, and caps the log" do
    state = %{interview: %{dialogue: []}}

    state = InterviewDialogue.add_dialogue(state, :mcp, "  First question?  ")
    state = InterviewDialogue.add_dialogue(state, :mcp, "First question?")
    state = InterviewDialogue.add_dialogue(state, :user, "  ")

    assert state.interview.dialogue == [%{role: :mcp, text: "First question?"}]
    assert state.interview.question == ""

    state =
      Enum.reduce(1..45, state, fn index, acc ->
        InterviewDialogue.add_dialogue(acc, :main, "answer #{index}")
      end)

    assert length(state.interview.dialogue) == 40
    assert hd(state.interview.dialogue) == %{role: :main, text: "answer 45"}
    refute Enum.any?(state.interview.dialogue, &(&1.text == "answer 1"))
  end

  test "add_dialogue drops leaked router prompts from main turns" do
    text = """
    You are the answerer/router half.

    Routing rules (from the interview SKILL)
    Output exactly one directive as the first line.
    ANSWER [from-code] <answer>
    ASK_USER <question for the human>
    """

    state = InterviewDialogue.add_dialogue(%{interview: %{dialogue: []}}, :main, text)

    assert state.interview.dialogue == []
    assert InterviewDialogue.leaked_router_prompt?(text)
    refute InterviewDialogue.leaked_router_prompt?("[from-code] Real answer")
  end

  test "add_router_trace and add_reasoning keep bounded newest-first buffers" do
    state =
      Enum.reduce(1..8, %{}, fn index, acc ->
        InterviewDialogue.add_router_trace(acc, "route #{index}")
      end)

    assert state.interview.router == [
             "route 8",
             "route 7",
             "route 6",
             "route 5",
             "route 4",
             "route 3"
           ]

    state =
      Enum.reduce(1..65, state, fn index, acc ->
        InterviewDialogue.add_reasoning(acc, "reason #{index}")
      end)

    assert length(state.interview.reasoning) == 60
    assert hd(state.interview.reasoning) == "reason 65"
    refute "reason 1" in state.interview.reasoning
  end

  test "mcp_turn_text keeps ambiguity score visible for the transcript" do
    assert InterviewDialogue.mcp_turn_text("(ambiguity: 0.42) Which workflow?") ==
             "(ambiguity 0.42) Which workflow?"

    assert InterviewDialogue.mcp_turn_text("  Which workflow?  ") == "Which workflow?"
  end

  test "ensure_answer_prefix preserves existing source and stamps missing source" do
    assert InterviewDialogue.ensure_answer_prefix("[from-code] Already sourced", :research) ==
             "[from-code] Already sourced"

    assert InterviewDialogue.ensure_answer_prefix("Read the config", :code) ==
             "[from-code] Read the config"
  end
end
