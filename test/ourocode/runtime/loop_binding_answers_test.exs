defmodule Ourocode.Runtime.LoopBindingAnswersTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.{InterviewWonderPrompt, LoopBindingAnswers, LoopBindingState}
  alias Ourocode.WonderTool.InteractionDetector

  setup do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)

    on_exit(fn -> stop_agent(agent) end)

    {:ok, agent: agent}
  end

  test "answer_interview records the answer and notifies a waiter", %{agent: agent} do
    parent = self()

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{parent_call_id: "parent-1", question: "Q?"},
          interview_waiter: parent
      }
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert LoopBindingAnswers.answer_interview(agent, "answer", enqueue) == {:ok, "answer"}
    assert_receive {:interview_answer, "answer"}
    assert_receive {:enqueued, %{type: :child_event}}

    assert Agent.get(agent, & &1.interview.answered) == "answer"
  end

  test "answer_wonder clears active wonder and relays handback to waiter", %{agent: agent} do
    parent = self()
    detection = wonder_detection()

    Agent.update(agent, fn state ->
      %{state | wonder: detection, interview_waiter: parent}
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert {:ok, %{selected_label: "B"}} = LoopBindingAnswers.answer_wonder(agent, 2, enqueue)
    assert_receive {:interview_answer, handback}
    assert handback =~ "B"
    assert_receive {:enqueued, %{type: :child_event}}

    assert Agent.get(agent, & &1.wonder) == nil
    assert Agent.get(agent, & &1.interview_waiter) == nil
  end

  test "cancel_wonder clears state and sends cancel to waiter", %{agent: agent} do
    parent = self()
    detection = wonder_detection()

    Agent.update(agent, fn state ->
      %{state | wonder: detection, interview_waiter: parent, paused: true}
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert {:ok, %{cancelled: true, reason: "decline"}} =
             LoopBindingAnswers.cancel_wonder(agent, "decline", enqueue)

    assert_receive {:interview_answer, "cancel"}
    assert_receive {:enqueued, %{type: :child_event}}

    assert Agent.get(agent, & &1.wonder) == nil
    assert Agent.get(agent, & &1.interview_waiter) == nil
    refute Agent.get(agent, & &1.paused)
  end

  defp wonder_detection do
    event =
      InterviewWonderPrompt.event("parent-1", 1, "Choose?", [
        %{"label" => "A", "description" => "first"},
        %{"label" => "B", "description" => "second"}
      ])

    assert {:ok, detection} = InteractionDetector.detect(event.payload)
    detection
  end

  defp stop_agent(agent) do
    if Process.alive?(agent) do
      Agent.stop(agent)
    end
  catch
    :exit, _reason -> :ok
  end
end
