defmodule Ourocode.Runtime.InterviewReasoningLineTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewReasoningLine

  test "formats basic state lines and float values" do
    assert InterviewReasoningLine.state_line(
             %{"ambiguity_score" => 0.125},
             "ambiguity_score",
             "ambiguity"
           ) ==
             "ambiguity: 0.13"

    assert InterviewReasoningLine.state_line(%{phase: "answer"}, "phase", "phase") ==
             "phase: answer"
  end

  test "formats pending question and rounds lines" do
    assert InterviewReasoningLine.state_line(
             %{"pending_question" => true},
             "pending_question",
             "pending"
           ) ==
             "pending: waiting for user answer"

    assert InterviewReasoningLine.state_line(
             %{"pending_question" => false},
             "pending_question",
             "pending"
           ) ==
             nil

    assert InterviewReasoningLine.rounds_line(%{"answered_rounds" => 2, "total_rounds" => 4}) ==
             "rounds: 2 answered / 4 total"
  end

  test "formats completion blockers and stability" do
    assert InterviewReasoningLine.completion_blockers_line(%{
             "completion_floor_failures" => ["missing AC", :needs_examples]
           }) == "completion blocked: missing AC; needs_examples"

    assert InterviewReasoningLine.stability_line(%{"completion_candidate_streak" => 1}) ==
             "stability: 1"

    assert InterviewReasoningLine.stability_line(%{
             "completion_candidate_streak" => 1,
             "streak_required" => 3
           }) == "stability: 1/3"
  end
end
