defmodule Ourocode.Runtime.LoopBindingInterviewAwaiterTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingInterviewAwaiter

  test "wait_state records the prompt, waiter, and active interview status" do
    state = %{
      interview: %{
        question: "Old?",
        parent_call_id: "old-parent",
        answered: "old answer"
      },
      interview_waiter: nil,
      paused: true
    }

    updated =
      LoopBindingInterviewAwaiter.wait_state(
        state,
        nil,
        "**Which payment provider?**",
        self()
      )

    assert updated.interview.question == "Which payment provider?"
    assert updated.interview.parent_call_id == "old-parent"
    assert updated.interview.waiting == false
    assert updated.interview.status == "waiting for your answer"

    assert Enum.map(updated.interview.question_options, & &1["label"]) == [
             "Answer in my own words",
             "Not sure — skip for now"
           ]

    refute Map.has_key?(updated.interview, :answered)
    assert updated.interview_waiter == self()
    assert updated.paused == false
  end

  test "wait_state stores final picker options with the prompt" do
    updated =
      LoopBindingInterviewAwaiter.wait_state(
        %{interview: %{}},
        "parent-1",
        "Which priority?",
        self(),
        [
          %{"label" => "Quality", "description" => "Raise reliability first"},
          %{"label" => "Speed", "description" => "Optimize turnaround first"}
        ]
      )

    assert Enum.map(updated.interview.question_options, & &1["label"]) == ["Quality", "Speed"]
  end

  test "wait_state uses a new parent call id when provided" do
    updated =
      LoopBindingInterviewAwaiter.wait_state(
        %{interview: %{parent_call_id: "old-parent"}},
        "new-parent",
        "Question?",
        self()
      )

    assert updated.interview.parent_call_id == "new-parent"
  end

  test "classify_answer separates terminal answers from normal answers" do
    assert LoopBindingInterviewAwaiter.classify_answer("done") == {:done, "done"}
    assert LoopBindingInterviewAwaiter.classify_answer("/cancel") == {:done, "/cancel"}

    assert LoopBindingInterviewAwaiter.classify_answer("Use Postgres") ==
             {:answer, "Use Postgres"}
  end

  test "await records waiter state and returns the next interview answer" do
    parent = self()

    {:ok, agent} =
      Agent.start_link(fn ->
        %{interview: %{parent_call_id: "old-parent"}, interview_waiter: nil, paused: true}
      end)

    task =
      Task.async(fn ->
        result = LoopBindingInterviewAwaiter.await(agent, "new-parent", "Question?")
        send(parent, {:await_result, result})
      end)

    assert %{interview_waiter: waiter} = wait_for_waiter(agent)
    assert is_pid(waiter)
    assert Agent.get(agent, & &1).interview.parent_call_id == "new-parent"

    send(waiter, {:interview_answer, "Use Postgres"})

    assert_receive {:await_result, {:answer, "Use Postgres"}}
    Task.await(task)
    Agent.stop(agent)
  end

  defp wait_for_waiter(agent, attempts \\ 20)

  defp wait_for_waiter(agent, attempts) when attempts > 0 do
    state = Agent.get(agent, & &1)

    if is_pid(Map.get(state, :interview_waiter)) do
      state
    else
      Process.sleep(5)
      wait_for_waiter(agent, attempts - 1)
    end
  end

  defp wait_for_waiter(agent, _attempts), do: Agent.get(agent, & &1)
end
