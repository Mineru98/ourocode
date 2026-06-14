defmodule Ourocode.Runtime.InterviewStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.InterviewState

  test "add_dialogue trims text, skips blanks, deduplicates latest turn, and caps the log" do
    state = %{interview: %{dialogue: []}}

    state = InterviewState.add_dialogue(state, :mcp, "  First question?  ")
    state = InterviewState.add_dialogue(state, :mcp, "First question?")
    state = InterviewState.add_dialogue(state, :user, "  ")

    assert state.interview.dialogue == [%{role: :mcp, text: "First question?"}]
    assert state.interview.question == ""

    state =
      Enum.reduce(1..45, state, fn index, acc ->
        InterviewState.add_dialogue(acc, :main, "answer #{index}")
      end)

    assert length(state.interview.dialogue) == 40
    assert hd(state.interview.dialogue) == %{role: :main, text: "answer 45"}
    refute Enum.any?(state.interview.dialogue, &(&1.text == "answer 1"))
  end

  test "add_dialogue drops leaked router prompts from main turns" do
    text = """
    You are the answerer/router half.

    Routing rules (from the interview SKILL)
    Output exactly one directive as the first line.
    ANSWER [from-code] <answer>
    ASK_USER <question for the human>
    """

    state = InterviewState.add_dialogue(%{interview: %{dialogue: []}}, :main, text)

    assert state.interview.dialogue == []
    assert InterviewState.leaked_router_prompt?(text)
    refute InterviewState.leaked_router_prompt?("[from-code] Real answer")
  end

  test "mcp_turn_text keeps ambiguity score visible for the transcript" do
    assert InterviewState.mcp_turn_text("(ambiguity: 0.42) Which workflow?") ==
             "(ambiguity 0.42) Which workflow?"

    assert InterviewState.mcp_turn_text("  Which workflow?  ") == "Which workflow?"
  end

  test "ensure_answer_prefix preserves existing source and stamps missing source" do
    assert InterviewState.ensure_answer_prefix("[from-code] Already sourced", :research) ==
             "[from-code] Already sourced"

    assert InterviewState.ensure_answer_prefix("Read the config", :code) ==
             "[from-code] Read the config"
  end

  test "merge_meta adds structured fields and skips empty values" do
    interview = %{question: "Existing?", session_id: "keep-me", mcp_reasoning: ["keep"]}

    merged =
      InterviewState.merge_meta(interview, %{
        "ambiguity_score" => "0.31",
        "milestone" => "scope",
        "seed_ready" => false,
        "ambiguity_breakdown" => %{"goal" => "unclear"},
        "session_id" => "",
        "internal_reasoning" => []
      })

    assert merged.ambiguity == 0.31
    assert merged.milestone == "scope"
    assert merged.seed_ready == false
    assert merged.breakdown == %{"goal" => "unclear"}
    assert merged.session_id == ""
    assert merged.mcp_reasoning == ["keep"]
  end

  test "detect folds ambiguity-prefixed interview events into state" do
    state = %{
      interview: %{
        answered: "old",
        question_options: [%{"label" => "Stale choice", "description" => "from old question"}]
      },
      paused: true
    }

    event = %{
      parent_call_id: "parent-1",
      child_id: "child-1",
      payload: %{
        "token" => "(ambiguity: 0.64) **Which UX area?**",
        "meta" => %{"milestone" => "scope", "seed_ready" => false}
      }
    }

    state = InterviewState.detect(state, event)

    assert state.paused == false
    assert state.interview.question == "Which UX area?"
    assert state.interview.ambiguity == 0.64
    assert state.interview.parent_call_id == "parent-1"
    assert state.interview.child_id == "child-1"
    assert state.interview.milestone == "scope"
    assert state.interview.seed_ready == false
    refute Map.has_key?(state.interview, :answered)
    refute Map.has_key?(state.interview, :question_options)
  end

  test "detect ignores parent call lifecycle start events as interview questions" do
    event =
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 1,
        transport: :streamable_http,
        parent_call_id: "parent-1",
        runtime_source: "ouroboros",
        external_ids: %{},
        occurred_at_ms: 1_000,
        request_id: "req-1",
        method: "tools/call",
        payload: %{"token" => "(ambiguity: 0.64) Question start"}
      })

    assert InterviewState.detect(%{}, event) == %{}
  end

  test "merge question clears stale waiting timer once the user can answer" do
    state = %{
      interview: %{
        question: "",
        status: "waiting for MCP interview question",
        waiting: true,
        waiting_started_monotonic_ms: 123
      }
    }

    updated =
      InterviewState.merge_question(
        state,
        "parent-1",
        "(ambiguity: 0.42) Which workflow should change?",
        %{},
        "iv-1"
      )

    assert updated.interview.question == "Which workflow should change?"
    assert updated.interview.waiting == false
    refute Map.has_key?(updated.interview, :waiting_started_monotonic_ms)
  end

  test "merge status does not overwrite an active question waiting for the user" do
    state = %{
      interview: %{
        parent_call_id: "parent-1",
        question: "Which workflow should change?",
        status: "waiting for your answer",
        waiting: false,
        question_options: [%{"label" => "Onboarding", "description" => "First-run flow"}]
      }
    }

    assert InterviewState.merge_status(
             state,
             "parent-1",
             "starting Socratic Interview",
             %{},
             "iv-1"
           ) == state
  end

  test "detect does not create a question from reasoning-only progress metadata" do
    state =
      InterviewState.detect(%{}, %{
        type: :parent_call_event,
        payload: %{
          "token" => "Question start",
          "meta" => %{"interview_reasoning" => %{"phase" => "start"}}
        }
      })

    assert state == %{}
  end

  test "detect merges meta-only interview updates into an active interview" do
    state = %{interview: %{question: "Existing?"}, paused: true}

    state =
      InterviewState.detect(state, %{
        payload: %{
          "meta" => %{
            "session_id" => "iv-1",
            "interview_reasoning" => %{"phase" => "answer", "milestone" => "scope"}
          }
        }
      })

    assert state.paused == true
    assert state.interview.question == "Existing?"
    assert state.interview.session_id == "iv-1"
    assert state.interview.mcp_reasoning == ["phase: answer", "milestone: scope"]
    assert state.interview.mcp_reasoning_state == %{"phase" => "answer", "milestone" => "scope"}
  end
end
