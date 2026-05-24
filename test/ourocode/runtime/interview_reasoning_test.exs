defmodule Ourocode.Runtime.InterviewReasoningTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewReasoning

  test "prefers explicit internal reasoning lines and trims blanks" do
    assert InterviewReasoning.lines(%{
             "internal_reasoning" => [" first ", "", :second],
             "interview_reasoning" => %{"phase" => "ignored"}
           }) == ["first", "second"]
  end

  test "splits multiline reasoning strings" do
    assert InterviewReasoning.lines(%{"mcp_reasoning" => "alpha\n\n beta \r\n gamma"}) == [
             "alpha",
             "beta",
             "gamma"
           ]
  end

  test "formats structured interview state into compact status lines" do
    assert InterviewReasoning.lines(%{
             "interview_reasoning" => %{
               "phase" => "answer",
               "session_id" => "session-1",
               "answered_rounds" => 2,
               "total_rounds" => 4,
               "pending_question" => true,
               "ambiguity_score" => 0.125,
               "milestone" => "scope",
               "seed_ready" => false,
               "completion_qualified" => false,
               "completion_floor_failures" => ["missing AC", :needs_examples],
               "completion_candidate_streak" => 1,
               "streak_required" => 3,
               "recoverable" => true,
               "question_chars" => 120,
               "next_action" => "ask"
             }
           }) == [
             "phase: answer",
             "session: session-1",
             "rounds: 2 answered / 4 total",
             "pending: waiting for user answer",
             "ambiguity: 0.13",
             "milestone: scope",
             "seed-ready: false",
             "completion-qualified: false",
             "completion blocked: missing AC; needs_examples",
             "stability: 1/3",
             "recoverable: true",
             "question_chars: 120"
           ]
  end

  test "returns no lines for absent or empty reasoning" do
    assert InterviewReasoning.lines(%{}) == []
    assert InterviewReasoning.lines(%{"interview_reasoning" => []}) == []
    assert InterviewReasoning.lines(nil) == []
  end
end
