defmodule Ourocode.Runtime.InterviewEventsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewEvents

  test "answer_ack records the user answer against the active interview child" do
    assert %{
             type: :child_event,
             event_type: :child_event,
             source: :interview,
             transport: :streamable_http,
             parent_call_id: "parent-1",
             child_id: "child-1",
             runtime_source: "ouroboros",
             occurred_at_ms: 100,
             payload: %{kind: :interview_answer, token: "you: PostgreSQL"}
           } =
             InterviewEvents.answer_ack(
               %{parent_call_id: "parent-1", child_id: "child-1"},
               "PostgreSQL",
               100
             )
  end

  test "server_error builds resumable status event and state projection" do
    event = InterviewEvents.server_error("parent-1", "model unavailable", "session-1", 200)

    assert event.payload.token ==
             "MCP question generator unavailable: model unavailable  (session=session-1, resume available)"

    state =
      %{interview: %{answered: "old"}, interview_waiter: self()}
      |> InterviewEvents.server_error_state("model unavailable", "session-1")

    assert state.interview.status == "MCP question generator unavailable: model unavailable"
    assert state.interview.resumable == true
    assert state.interview.session_id == "session-1"
    refute Map.has_key?(state.interview, :answered)
    assert state.interview_waiter == nil
  end

  test "complete event and state mark the interview seed-ready" do
    event = InterviewEvents.complete("parent-1", :seed_ready, 300)

    assert event.payload.kind == :interview_complete
    assert event.payload["meta"] == %{"seed_ready" => true}
    assert event.payload.token =~ "ooo seed"

    state =
      %{
        interview: %{waiting: true},
        interview_session: %{id: "session-1"},
        interview_waiter: self()
      }
      |> InterviewEvents.complete_state(:seed_ready)

    assert state.interview.seed_ready == true
    assert state.interview.complete == :seed_ready
    assert state.interview.waiting == false
    assert state.interview_session == nil
    assert state.interview_waiter == nil
  end

  test "failure event keeps inspected reason in parent failure payload" do
    assert %{
             type: :parent_call_failed,
             event_type: :parent_call_failed,
             parent_call_id: "parent-1",
             payload: %{status: :failed, reason: "{:transport_failed, :timeout}"}
           } = InterviewEvents.failure("parent-1", {:transport_failed, :timeout}, 400)
  end
end
