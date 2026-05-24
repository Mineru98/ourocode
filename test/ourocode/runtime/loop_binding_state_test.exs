defmodule Ourocode.Runtime.LoopBindingStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingState

  test "initial state contains empty panes, workflow context, and inbox" do
    state = LoopBindingState.initial()

    assert :queue.is_empty(state.inbox)
    assert state.parent.working == []
    assert state.parent.completed == []
    assert state.child.working == []
    assert state.workflow == %{}
    assert state.ouroboros_activity == []
    assert state.paused == false
  end

  test "snapshot projects runtime panes and interaction state" do
    {:ok, agent} =
      Agent.start_link(fn ->
        LoopBindingState.initial()
        |> Map.put(:wonder, %{question: "Pick one"})
        |> Map.put(:interview, %{question: "Clarify scope"})
        |> Map.put(:interview_session, %{session_id: "session-1"})
        |> Map.put(:paused, true)
      end)

    snapshot = LoopBindingState.snapshot(agent, 24)

    assert snapshot.runtime.parent_panes == LoopBindingState.initial().parent
    assert snapshot.runtime.child_panes == LoopBindingState.initial().child
    assert snapshot.wonder_tool == %{question: "Pick one"}
    assert snapshot.interview == %{question: "Clarify scope"}
    assert snapshot.interview_session == %{session_id: "session-1"}
    assert snapshot.paused == true
  end
end
