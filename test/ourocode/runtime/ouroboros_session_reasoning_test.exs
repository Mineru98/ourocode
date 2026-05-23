defmodule Ourocode.Runtime.OuroborosSessionReasoningTest do
  use ExUnit.Case, async: false

  alias Ourocode.Runtime.OuroborosSessionReasoning

  setup do
    previous_ouroboros_home = System.get_env("OUROCODE_OUROBOROS_HOME")
    home = Path.join(System.tmp_dir!(), "ourocode-home-#{System.unique_integer([:positive])}")
    ouroboros_home = Path.join(home, ".ouroboros")
    File.mkdir_p!(Path.join([ouroboros_home, "data"]))
    System.put_env("OUROCODE_OUROBOROS_HOME", ouroboros_home)

    on_exit(fn ->
      if previous_ouroboros_home,
        do: System.put_env("OUROCODE_OUROBOROS_HOME", previous_ouroboros_home),
        else: System.delete_env("OUROCODE_OUROBOROS_HOME")

      File.rm_rf(home)
    end)

    %{ouroboros_home: ouroboros_home}
  end

  test "loads persisted interview state as right-panel reasoning", %{ouroboros_home: home} do
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

    File.write!(
      Path.join([home, "data", "interview_interview_session_state.json"]),
      Ourocode.Json.encode!(state)
    )

    assert {lines, reasoning_state} = OuroborosSessionReasoning.load("interview_session_state")

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
    assert reasoning_state["source"] == "session_state"
  end

  test "loads activity previews from persisted interview state", %{ouroboros_home: home} do
    File.write!(
      Path.join([home, "data", "interview_interview_activity.json"]),
      Ourocode.Json.encode!(%{
        "interview_id" => "interview_activity",
        "initial_context" => "ooo interview improve the right panel",
        "rounds" => [
          %{
            "round_number" => 1,
            "question" => "Which panel should surface the MCP reasoning?",
            "user_response" => nil
          }
        ]
      })
    )

    assert Ourocode.Runtime.OuroborosSessionReasoning.load_activity_context("interview_activity") ==
             %{
               session_id: "interview_activity",
               initial_context: "ooo interview improve the right panel",
               questions: %{1 => "Which panel should surface the MCP reasoning?"}
             }
  end

  test "missing persisted state returns no reasoning" do
    assert OuroborosSessionReasoning.load("missing") == {[], %{}}
  end
end
