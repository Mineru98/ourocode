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
