defmodule Ourocode.Runtime.InterviewTurnTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewTurn

  test "classifies empty and non-binary responses as server errors" do
    assert InterviewTurn.classify_response("") ==
             {:server_error, "empty response from the MCP question generator"}

    assert InterviewTurn.classify_response(nil) ==
             {:server_error, "empty response from the MCP question generator"}
  end

  test "classifies completed interview responses" do
    assert :complete =
             InterviewTurn.classify_response("""
             Interview completed. Session ID: interview_x

             Ready for Seed generation.
             Generate a Seed with: ooo seed
             """)
  end

  test "classifies question-generation failures with boilerplate removed" do
    assert {:server_error, message} =
             InterviewTurn.classify_response("""
             Question generation failed after retries because the router timed out.

             Session ID: interview_x
             Resume with: ooo interview session_id=interview_x
             """)

    assert message == "Question generation failed after retries because the router timed out"
  end

  test "classifies normal responses as interview questions" do
    assert {:question, "Which workflow should we improve first?"} =
             InterviewTurn.classify_response("""
             (ambiguity: 0.42) Which workflow should we improve first?
             """)
  end

  test "classifies delegated subagent JSON status payloads as waiting state, not questions" do
    text =
      Ourocode.Json.encode!(%{
        status: "delegated_to_subagent",
        session_id: "interview_123",
        pending_question: false,
        next_action: "wait for OpenCode child interview"
      })
      |> IO.iodata_to_binary()

    assert InterviewTurn.classify_response(text) ==
             {:waiting, "wait for OpenCode child interview"}
  end

  test "classifies agent task JSON payloads as waiting state, not questions" do
    text =
      Ourocode.Json.encode!(%{
        agent: "Socratic Interview",
        general: "Run the interview in a delegated child session.",
        context: "The parent UI should wait for the child result.",
        action: "Question start"
      })
      |> IO.iodata_to_binary()

    assert InterviewTurn.classify_response(text) ==
             {:waiting, "starting Socratic Interview"}
  end
end
