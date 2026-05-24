defmodule Ourocode.Runtime.InterviewProgressTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewProgress

  test "marks interview dispatching with user prompt dialogue" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{interview: nil, interview_session: nil, paused: true}
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    InterviewProgress.mark_dispatching(
      agent,
      %{task_input: "ooo interview improve docs"},
      "parent-1"
    )

    state = Agent.get(agent, & &1)
    assert state.paused == false
    assert state.interview.waiting == true
    assert state.interview.status == "starting interview session"
    assert state.interview.parent_call_id == "parent-1"
    assert [%{role: :user, text: "ooo interview improve docs"}] = state.interview.dialogue
    assert state.interview_session.round == 0
  end

  test "marks interview waiting rounds with stable status text" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          interview: %{parent_call_id: "previous", answered: "old"},
          interview_session: nil,
          paused: true
        }
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    InterviewProgress.mark_waiting(agent, %{parent_call_id: "parent-2", round: 2})

    state = Agent.get(agent, & &1)
    assert state.interview.parent_call_id == "parent-2"
    assert state.interview.status == "waiting for MCP follow-up question"
    refute Map.has_key?(state.interview, :answered)
    assert state.interview_session.round == 2
    assert InterviewProgress.waiting_status(1) == "waiting for MCP interview question"
  end
end
