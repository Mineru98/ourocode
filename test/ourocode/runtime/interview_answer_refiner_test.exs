defmodule Ourocode.Runtime.InterviewAnswerRefinerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewAnswerRefiner

  test "short picker-like answers do not require refinement" do
    refute InterviewAnswerRefiner.needs_refine?("Stripe")
    refute InterviewAnswerRefiner.needs_refine?("Yes")
    refute InterviewAnswerRefiner.needs_refine?("[from-code] Elixir project")
  end

  test "free-text answers carrying scope or reasoning require refinement" do
    assert InterviewAnswerRefiner.needs_refine?(
             "Use Stripe because subscriptions are the core business model, but leave refunds out of scope."
           )
  end

  test "payload preserves decision, reasoning, constraints, and scope sections" do
    payload =
      InterviewAnswerRefiner.payload(
        "Use Stripe because subscriptions are the core business model, but leave refunds out of scope.",
        question: "Which payment provider should we integrate?"
      )

    assert payload =~ "[from-user][refined]"
    assert payload =~ "Decision:"
    assert payload =~ "Reasoning:"
    assert payload =~ "Constraints (user-stated):"
    assert payload =~ "Out of scope (user-stated):"
    assert payload =~ "MCP question: Which payment provider should we integrate?"
  end

  test "send as-is accepts the structured payload" do
    payload = InterviewAnswerRefiner.payload("Use Stripe because subscriptions are core.")

    assert {:send, ^payload} =
             InterviewAnswerRefiner.apply_refine_choice(payload, "Send as-is", "ignored")
  end
end
