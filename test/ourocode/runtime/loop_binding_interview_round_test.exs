defmodule Ourocode.Runtime.LoopBindingInterviewRoundTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingInterviewRound

  test "transport errors become transport-failed actions" do
    assert LoopBindingInterviewRound.action({:error, :closed}, nil) ==
             {:transport_failed, :closed}
  end

  test "server error responses keep extracted session id" do
    result = parent_result("Question generation failed after retries. Session ID: interview-1")

    assert LoopBindingInterviewRound.action({:ok, result}, nil) ==
             {:server_error, "Question generation failed after retries", "interview-1"}
  end

  test "complete responses include text metadata and session id" do
    result =
      parent_result("Interview completed. Session ID: interview-1\nReady for Seed generation.")

    assert {:complete, text, meta, "interview-1"} =
             LoopBindingInterviewRound.action({:ok, result}, nil)

    assert text =~ "Interview completed"
    assert is_map(meta)
  end

  test "question responses require a session id and carry normalized question data" do
    result = parent_result("Session ID: interview-1\n(ambiguity: 0.42) Which workflow?")

    assert LoopBindingInterviewRound.action({:ok, result}, nil) ==
             {:question, "Which workflow?",
              "Session ID: interview-1\n(ambiguity: 0.42) Which workflow?", %{}, "interview-1"}

    assert LoopBindingInterviewRound.action({:ok, parent_result("Which workflow?")}, nil) ==
             :missing_session_id

    assert {:question, "Which workflow?", _text, _meta, "existing"} =
             LoopBindingInterviewRound.action({:ok, parent_result("Which workflow?")}, "existing")
  end

  test "delegated subagent status payloads stay in waiting state instead of becoming questions" do
    text =
      Ourocode.Json.encode!(%{
        status: "delegatedtosubagent",
        sessionid: "interview_456",
        pendingquestion: false,
        nextaction: "wait for OpenCode child interview"
      })
      |> IO.iodata_to_binary()

    assert {:waiting, "wait for OpenCode child interview", meta, "interview_456"} =
             LoopBindingInterviewRound.action({:ok, parent_result(text)}, nil)

    assert meta["status"] == "delegatedtosubagent"
  end

  test "agent task payloads stay in waiting state instead of becoming questions" do
    text =
      Ourocode.Json.encode!(%{
        agent: "Socratic Interview",
        general: "Run the interview outside the parent TUI.",
        context: "The parent should not render this status payload as the question.",
        action: "Question start"
      })
      |> IO.iodata_to_binary()

    assert {:waiting, "starting Socratic Interview", meta, "existing-session"} =
             LoopBindingInterviewRound.action({:ok, parent_result(text)}, "existing-session")

    assert meta["agent"] == "Socratic Interview"
  end

  test "initial-context-too-large meta asks the main session to summarize instead of asking user" do
    result =
      parent_result("Please summarize the initial context.",
        meta: %{
          "session_id" => "iv-large-1",
          "reason" => "initial_context_too_large",
          "recoverable" => true,
          "max_chars" => 120
        }
      )

    assert {:summarize_initial_context, meta, "iv-large-1"} =
             LoopBindingInterviewRound.action({:ok, result}, nil)

    assert meta["reason"] == "initial_context_too_large"
  end

  defp parent_result(text, opts \\ []) do
    %{
      response: %{
        "result" => %{
          "meta" => Keyword.get(opts, :meta, %{}),
          "content" => [%{"type" => "text", "text" => text}]
        }
      }
    }
  end
end
