defmodule Ourocode.Runtime.OuroborosSessionProjectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosSessionProjection

  test "projects pending persisted interview state into reasoning lines and state" do
    state = %{
      "interview_id" => "interview_session_state",
      "status" => "in_progress",
      "rounds" => [
        %{
          "round_number" => 1,
          "question" => "Which UX surface should be improved first?",
          "user_response" => nil
        }
      ],
      "is_brownfield" => true,
      "ambiguity_score" => 0.42,
      "completion_candidate_streak" => 0
    }

    assert {lines, reasoning_state} =
             OuroborosSessionProjection.reasoning(state, "fallback_session")

    assert lines == [
             "phase: question",
             "session: interview_session_state",
             "rounds: 0 answered / 1 total",
             "pending: waiting for user answer",
             "brownfield: true",
             "ambiguity: 0.42",
             "stability: 0",
             "status: in_progress",
             "question_chars: 42",
             "next: ask user to answer pending question",
             "source: session_state"
           ]

    assert reasoning_state["pending_question"] == true
    assert reasoning_state["session_id"] == "interview_session_state"
    assert reasoning_state["source"] == "session_state"
  end

  test "uses fallback session id and completed state defaults" do
    assert {lines, reasoning_state} =
             OuroborosSessionProjection.reasoning(
               %{
                 "status" => "completed",
                 "rounds" => [
                   %{"round_number" => 1, "question" => "Done?", "user_response" => "yes"}
                 ]
               },
               "fallback_session"
             )

    assert "phase: complete" in lines
    assert "session: fallback_session" in lines
    assert "seed-ready: true" in lines
    assert reasoning_state["seed_ready"] == true
  end

  test "projects activity context previews from persisted rounds" do
    context =
      OuroborosSessionProjection.activity_context(%{
        "interview_id" => "interview_activity",
        "initial_context" => "ooo interview   improve\n  the right panel",
        "rounds" => [
          %{
            "round_number" => 1,
            "question" => "Which panel should surface the MCP reasoning?",
            "user_response" => nil
          }
        ]
      })

    assert context == %{
             session_id: "interview_activity",
             initial_context: "ooo interview improve the right panel",
             questions: %{1 => "Which panel should surface the MCP reasoning?"}
           }
  end

  test "empty persisted state projects to empty results" do
    assert OuroborosSessionProjection.reasoning(%{}, "fallback") == {[], %{}}
    assert OuroborosSessionProjection.activity_context(%{}) == %{}
  end
end
