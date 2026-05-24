defmodule Ourocode.Terminal.InterviewHandoffTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewHandoff

  test "prompt wraps a paused interview question and user message" do
    prompt = InterviewHandoff.prompt("Which provider?", "Compare Stripe and Toss")

    assert prompt =~ "An interview checkpoint is paused"
    assert prompt =~ "Pending interview question:\nWhich provider?"
    assert prompt =~ "User message:\nCompare Stripe and Toss"
    assert prompt =~ "INTERVIEW_ANSWER: <concise answer to submit>"
  end

  test "extract_answer reads the last explicit handoff line" do
    assert InterviewHandoff.extract_answer("""
           Earlier thought.
           INTERVIEW_ANSWER: Stripe
           More discussion.
           INTERVIEW_ANSWER: Toss for Korean KRW billing
           """) == "Toss for Korean KRW billing"
  end

  test "extract_answer ignores normal responses" do
    assert InterviewHandoff.extract_answer("No final handoff yet.") == nil
    assert InterviewHandoff.extract_answer(nil) == nil
  end
end
