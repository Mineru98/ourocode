defmodule Ourocode.Runtime.LoopBindingInterviewSessionIOTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingInterviewSessionIO

  setup do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{interview: %{dialogue: []}, interview_session: nil, interview_waiter: nil}
      end)

    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)
    %{agent: agent}
  end

  test "pushes dialogue, router traces, and reasoning into interview state", %{agent: agent} do
    assert :ok = LoopBindingInterviewSessionIO.push_dialogue(agent, :user, "  Build a CLI  ")
    assert :ok = LoopBindingInterviewSessionIO.push_router_trace(agent, "PATH 1")
    assert :ok = LoopBindingInterviewSessionIO.push_reasoning(agent, "thinking")

    state = Agent.get(agent, & &1)

    assert state.interview.dialogue == [%{role: :user, text: "Build a CLI"}]
    assert state.interview.router == ["PATH 1"]
    assert state.interview.reasoning == ["thinking"]
  end

  test "merges interview question state", %{agent: agent} do
    assert :ok =
             LoopBindingInterviewSessionIO.merge_interview(
               agent,
               "parent-1",
               "(ambiguity: 0.42) Which workflow?",
               %{"session_id" => "session-1"},
               "session-1"
             )

    state = Agent.get(agent, & &1)

    assert state.interview.parent_call_id == "parent-1"
    assert state.interview.question == "Which workflow?"
    assert state.interview.session_id == "session-1"
  end

  test "enqueue_complete emits event and marks state complete", %{agent: agent} do
    callbacks = %{enqueue: fn _agent, event -> send(self(), {:enqueued, event}) end}

    assert :ok =
             LoopBindingInterviewSessionIO.enqueue_complete(
               agent,
               "parent-1",
               :seed_ready,
               callbacks
             )

    assert_receive {:enqueued, %{type: :child_event, payload: %{kind: :interview_complete}}}

    state = Agent.get(agent, & &1)
    assert state.interview.complete == :seed_ready

    assert [%{role: :mcp, text: "interview complete (seed_ready) — next: ooo seed"} | _] =
             state.interview.dialogue
  end

  test "enqueue_failure emits failure event and clears waiting state", %{agent: agent} do
    callbacks = %{enqueue: fn _agent, event -> send(self(), {:enqueued, event}) end}

    Agent.update(agent, fn state ->
      %{
        state
        | interview: Map.merge(state.interview, %{waiting: true}),
          interview_session: %{id: "session-1"},
          interview_waiter: self()
      }
    end)

    assert :ok =
             LoopBindingInterviewSessionIO.enqueue_failure(
               agent,
               "parent-1",
               {:router_failed, :timeout},
               callbacks
             )

    assert_receive {:enqueued,
                    %{
                      type: :parent_call_failed,
                      parent_call_id: "parent-1",
                      payload: %{reason: "{:router_failed, :timeout}"}
                    }}

    state = Agent.get(agent, & &1)

    assert state.interview.status ==
             "interview failed; submit the same command to retry"

    assert state.interview.waiting == false
    assert state.interview_session == nil
    assert state.interview_waiter == nil

    assert [
             %{role: :mcp, text: "interview failed; submit the same command to retry"}
             | _
           ] =
             state.interview.dialogue
  end
end
