defmodule Ourocode.Runtime.LoopBindingRouterDecisionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingRouterDecision

  test "answer decisions become followup actions with dialogue text and streak" do
    assert LoopBindingRouterDecision.action(
             {:answer, "Read config.ex", :code},
             "Which file?",
             2
           ) == {:followup, "Read config.ex", 3, "[from-code] Read config.ex"}

    assert LoopBindingRouterDecision.action(
             {:answer, "[from-user] I prefer manual review", :user},
             "Which path?",
             5
           ) ==
             {:followup, "[from-user] I prefer manual review", 0,
              "[from-user] I prefer manual review"}
  end

  test "leaked router prompts are converted into ask-user actions" do
    leaked = """
    You are the answerer/router half.
    Routing rules (from the interview SKILL)
    Output exactly one directive as the first line.
    ANSWER [from-code] <answer>
    ASK_USER <question for the human>
    """

    assert LoopBindingRouterDecision.action({:answer, leaked, :code}, "Real question?", 1) ==
             {:ask_user, "Real question?", [], :leaked_prompt}
  end

  test "ask-user and error decisions pass through with action tags" do
    assert LoopBindingRouterDecision.action({:ask_user, "Pick one", ["A", "B"]}, "Q", 0) ==
             {:ask_user, "Pick one", ["A", "B"], :router}

    assert LoopBindingRouterDecision.action({:error, :timeout}, "Q", 0) == {:error, :timeout}
  end
end
