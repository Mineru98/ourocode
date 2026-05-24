defmodule Ourocode.Runtime.OuroborosSessionStatusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosSessionStatus

  test "maps terminal statuses before round-derived phases" do
    summary = %{answered_rounds: 0, total_rounds: 1, pending_question?: true}

    assert OuroborosSessionStatus.phase("completed", summary) == "complete"
    assert OuroborosSessionStatus.phase("failed", summary) == "failed"

    assert OuroborosSessionStatus.next_action("completed", summary) ==
             "generate seed or run next step"

    assert OuroborosSessionStatus.next_action("failed", summary) == "inspect failure and retry"
  end

  test "maps round summaries to active phases and next actions" do
    assert OuroborosSessionStatus.phase(nil, %{
             answered_rounds: 0,
             total_rounds: 1,
             pending_question?: true
           }) == "question"

    assert OuroborosSessionStatus.next_action(nil, %{
             answered_rounds: 0,
             total_rounds: 1,
             pending_question?: true
           }) == "ask user to answer pending question"

    assert OuroborosSessionStatus.phase(nil, %{
             answered_rounds: 0,
             total_rounds: 0,
             pending_question?: false
           }) == "start"

    assert OuroborosSessionStatus.phase(nil, %{
             answered_rounds: 2,
             total_rounds: 2,
             pending_question?: false
           }) == "answer"
  end

  test "completed status forces seed ready" do
    assert OuroborosSessionStatus.seed_ready?("completed", false) == true
    assert OuroborosSessionStatus.seed_ready?("in_progress", false) == false
  end
end
