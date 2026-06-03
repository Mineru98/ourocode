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

  test "answer_interview buffers a fast answer until the interview waiter exists", %{agent: agent} do
    parent = self()

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{
            parent_call_id: "parent-fast",
            question: "What should this produce?",
            status: "waiting for your answer",
            waiting: false
          },
          interview_waiter: nil
      }
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert LoopBindingAnswers.answer_interview(agent, "Define the outcome", enqueue) ==
             {:ok, "Define the outcome"}

    assert_receive {:enqueued, %{type: :child_event}}
    refute_receive {:interview_answer, _answer}, 50

    state = Agent.get(agent, & &1)
    assert state.pending_interview_answer == "Define the outcome"
    assert state.interview.waiting == true
    assert state.interview.status == "answer accepted - preparing next question"
    assert state.interview.last_answered_question == "What should this produce?"
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
    assert_receive {:enqueued, %{type: :decision_answered, selected_label: "B"}}

    assert Agent.get(agent, & &1.wonder) == nil
    assert Agent.get(agent, & &1.interview_waiter) == nil
  end

  test "answer_wonder buffers a fast answer until the interview waiter exists", %{agent: agent} do
    parent = self()
    detection = wonder_detection()

    Agent.update(agent, fn state ->
      %{state | wonder: detection, interview_waiter: nil}
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert {:ok, %{selected_label: "A"}} = LoopBindingAnswers.answer_wonder(agent, 1, enqueue)
    assert_receive {:enqueued, %{type: :child_event}}
    assert_receive {:enqueued, %{type: :decision_answered, selected_label: "A"}}
    refute_receive {:interview_answer, _answer}, 50

    state = Agent.get(agent, & &1)
    assert state.wonder == nil
    assert state.pending_interview_answer =~ "A"
  end

  test "answer_wonder keeps an accepted interview transition visible", %{agent: agent} do
    parent = self()
    detection = wonder_detection()

    Agent.update(agent, fn state ->
      %{
        state
        | wonder: detection,
          interview: %{parent_call_id: "parent-1"},
          interview_waiter: nil
      }
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert {:ok, %{selected_label: "B"}} = LoopBindingAnswers.answer_wonder(agent, 2, enqueue)

    state = Agent.get(agent, & &1)
    assert state.wonder == nil
    assert state.interview.waiting == true
    assert state.interview.question == ""
    assert state.interview.last_answer =~ "B"
    assert state.interview.last_answered_question == "Choose?"
    assert state.interview.status == "answer accepted - preparing next question"
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
    assert_receive {:enqueued, %{type: :decision_cancelled, reason: "decline"}}

    assert Agent.get(agent, & &1.wonder) == nil
    assert Agent.get(agent, & &1.interview_waiter) == nil
    refute Agent.get(agent, & &1.paused)
  end

  test "cancel_interview completes state immediately and notifies waiter", %{agent: agent} do
    parent = self()

    Agent.update(agent, fn state ->
      %{
        state
        | interview: %{parent_call_id: "parent-1", question: "Continue?", waiting: true},
          interview_waiter: parent,
          paused: true
      }
    end)

    enqueue = fn _agent, event -> send(parent, {:enqueued, event}) end

    assert {:ok, "cancel"} = LoopBindingAnswers.cancel_interview(agent, enqueue)

    assert_receive {:interview_answer, "cancel"}
    assert_receive {:enqueued, %{payload: %{kind: :interview_answer}}}
    assert_receive {:enqueued, %{payload: %{kind: :interview_complete}}}

    state = Agent.get(agent, & &1)
    assert state.interview.complete == :user_done
    assert state.interview.waiting == false
    assert state.interview_waiter == nil
    assert MapSet.member?(state.cancelled_interviews, "parent-1")
    refute state.paused
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
