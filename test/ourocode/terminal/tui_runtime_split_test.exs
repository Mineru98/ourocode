defmodule Ourocode.Terminal.TuiRuntimeSplitTest do
  @moduledoc """
  When a runtime workflow is live, the body splits into a scrollable
  conversation transcript on the left and MCP internals (parent workflow on
  top, child session stream on the bottom) on the right. With no live panes
  the calm single transcript stays.
  """

  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{InterviewPanel, Tui}

  @idle_frame """
  +-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
  | app=ourocode status=healthy runtime=ready session=terminal-1
  +--
  +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
  | [parent-region] x=0 y=0 w=80 h=8
  | parent empty
  | [child-region] x=0 y=9 w=80 h=12
  | child empty
  +--
  +-- State
  | surface=terminal focus=task_prompt layout=compact
  | runtime=ready stream=streaming journal=ready
  | queued=0 replayable?=false transports=stdio,sse,streamable_http
  +--
  """

  @live_frame """
  +-- ourocode terminal region=header_status x=0 y=0 w=88 h=5
  | app=ourocode status=healthy runtime=ready session=terminal-1
  +--
  +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
  | [parent-region] x=0 y=0 w=80 h=8
  | parent parent=parent-1 transport=streamable_http status=streaming
  | [child-region] x=0 y=9 w=80 h=12
  | child child=child-1 token=interview-question-1
  +--
  +-- State
  | surface=terminal focus=task_prompt layout=compact
  | runtime=ready stream=streaming journal=ready
  | queued=0 replayable?=false transports=stdio,sse,streamable_http
  +--
  """

  defp render(frame, activity, scroll \\ 0) do
    Tui.frame_lines(frame, activity, "", 100, 24, %{scroll: scroll})
    |> Enum.join("\n")
  end

  test "idle frame stays a single calm transcript (no split)" do
    text = render(@idle_frame, ["you> hi", "ourocode> hello there"])

    refute text =~ "MCP parent"
    refute text =~ "child stream"
    assert text =~ "hello there"
  end

  test "live workflow splits transcript left, MCP internals right" do
    text = render(@live_frame, ["you> ooo interview", "ourocode> dispatching"])

    assert text =~ "MCP graph"
    assert text =~ "pane ledgers"
    assert text =~ "parent-1"
    assert text =~ "child=child-1"

    # Left side still carries the conversation transcript.
    assert text =~ "dispatching"

    # The vertical separator proves a real two-column split, not inlined text.
    assert text =~ "│"
  end

  test "interview renders as one focused block without right telemetry" do
    block =
      {"INTERVIEW",
       [
         "Which MCP transport should the interview prioritize?",
         "1. stdio - local process pipe",
         "2. streamable HTTP - remote streaming"
       ], "type answer   /cancel stop   Esc pause"}

    reasoning = ["ambiguity 0.42", "milestone scope", "seed-ready: no"]

    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 100, 24, %{
        interview_block: block,
        interview_reasoning: reasoning
      })
      |> Enum.join("\n")

    # No modal box; the question is a prominent left-column block.
    refute text =~ "+- wonderTool"
    assert text =~ "INTERVIEW"
    assert text =~ "Which MCP transport should the interview prioritize?"
    assert text =~ "type answer"

    # Interview questions own the body; internal reasoning stays out of the
    # decision surface.
    refute text =~ "MCP parent"
    refute text =~ "ambiguity 0.42"
    refute text =~ "milestone scope"
  end

  test "a long interview block uses the left column without shrinking the right panel" do
    long_question =
      "Which exact right-panel moment feels rough or interrupted across panel switching, " <>
        "streaming text, scroll behavior, and color treatment? final sentence"

    block =
      {"INTERVIEW",
       [
         "Interview",
         long_question,
         ">> [1] panel transition - the switch feels abrupt",
         "   [2] streaming - text jumps during updates"
       ], "Up/Dn pick   1-9 shortcut   Enter confirms   type answer   /cancel stop   Esc pause"}

    plain =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 120, 30, %{})

    with_block =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 120, 30, %{
        interview_block: block,
        interview_reasoning: ["waiting for your answer"]
      })

    assert Enum.join(with_block, "\n") =~ "final sentence"
    assert Enum.join(with_block, "\n") =~ ">> [1] panel transition"

    assert line_index(plain, "MCP graph")
    refute Enum.join(with_block, "\n") =~ "MCP graph"
    refute Enum.join(with_block, "\n") =~ "● interview live"
  end

  test "active wonder picker focuses the decision and hides the right pane" do
    block =
      {"INTERVIEW",
       [
         "UX checkpoint",
         "Which behavior should change first?",
         ">> [1] Arrow navigation - selection should move",
         "   [2] Visual focus - dim everything else"
       ], "Up/Dn pick   1-9 shortcut   Enter confirms   type answer   /cancel stop   Esc pause"}

    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "custom thought", 100, 24, %{
        interview_block: block,
        interview_reasoning: ["ambiguity 0.42"],
        wonder_focus: true
      })
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ ">> [1] Arrow navigation"
    assert text =~ "Custom answer: custom thought"
    assert text =~ "Enter confirm"
    refute text =~ "MCP parent"
    refute text =~ "child stream"
  end

  test "interview option block focuses the decision even before wonder focus catches up" do
    block =
      {"INTERVIEW",
       [
         "Interview",
         "Which surface should get fixed first?",
         ">> [1] Question handoff - show the choices immediately",
         "   [2] Sidebar noise - hide internal telemetry"
       ], "Up/Dn pick   1-9 shortcut   Enter confirms   type answer   Esc pause"}

    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 100, 24, %{
        interview_block: block,
        interview_reasoning: ["step waiting - waiting for your answer"],
        wonder_focus: false
      })
      |> Enum.join("\n")

    assert text =~ "Which surface should get fixed first?"
    assert text =~ ">> [1] Question handoff"
    assert text =~ "Enter confirm"
    refute text =~ "MCP parent"
    refute text =~ "activity log"
  end

  test "right column is MCP-internal only; router/reasoning live in the LEFT block" do
    interview = %{
      ambiguity: 0.42,
      milestone: "scope",
      seed_ready: true,
      complete: :seed_ready,
      session_id: "interview_x",
      router: ["ANSWER [code]: Elixir 1.15 escript CLI (mix.exs)", "TOOL READ mix.exs"],
      reasoning: ["the project is Elixir; this is a code-answerable fact", "older chunk"]
    }

    result = %{pane_snapshot: fn -> %{interview: interview, paused: false} end}

    right = Tui.interview_reasoning_lines(result)
    left = Tui.interview_working_lines(result, 0)

    # Right = MCP-internal wire facts only.
    assert "ambiguity 0.42" in right
    assert "seed-ready: yes" in right
    assert "interview complete: seed_ready" in right
    assert "session interview_x" in right
    refute Enum.any?(right, &(&1 =~ "ANSWER" or &1 =~ "TOOL" or &1 =~ "code-answerable"))

    # Left = an animated activity line carrying ONLY the latest clean router
    # trace; the raw streamed reasoning never leaks here.
    assert [activity] = left
    assert activity =~ "main session answered: Elixir 1.15 escript CLI (mix.exs)"
    refute activity =~ "ANSWER"
    refute activity =~ "code-answerable fact"
    refute activity =~ "older chunk"
    refute activity =~ "TOOL READ mix.exs"
  end

  test "right column prefers MCP-provided internal reasoning lines" do
    interview = %{
      ambiguity: 0.31,
      milestone: "scope",
      seed_ready: false,
      session_id: "interview_meta",
      mcp_reasoning: [
        "step: answer",
        "rounds: 1 answered / 2 total",
        "next: ask user to answer pending question"
      ]
    }

    result = %{pane_snapshot: fn -> %{interview: interview, paused: false} end}

    right = Tui.interview_reasoning_lines(result)

    assert "step: answer" in right
    assert "rounds: 1 answered / 2 total" in right
    assert "next: ask user to answer pending question" in right

    refute "ambiguity 0.31" in right
    refute "milestone scope" in right
    refute "seed-ready: no" in right
  end

  test "right column can show Ouroboros activity without pretending it is reasoning" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{
            status: "waiting for mcp follow-up question",
            mcp_activity: [
              "interview started · session 1",
              "round 1 · question generated · 128 chars"
            ]
          },
          paused: false
        }
      end
    }

    right = Tui.interview_reasoning_lines(result)
    activity = Tui.mcp_activity_lines(result)

    refute Enum.any?(right, &String.starts_with?(&1, "activity:"))
    assert "activity: interview started · session 1" in activity
    assert "activity: round 1 · question generated · 128 chars" in activity
  end

  test "right column puts activity log in its own lower stream" do
    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 120, 30, %{
        interview_reasoning: ["step: answer"],
        mcp_activity: [
          "activity: interview started · session 1",
          "activity: round 1 · question generated · 128 chars"
        ]
      })
      |> Enum.join("\n")

    assert text =~ "interview"
    assert text =~ "MCP graph"
    assert text =~ "pane ledgers"
    assert text =~ "activity log live"

    assert line_index(String.split(text, "\n"), "activity log") >
             line_index(String.split(text, "\n"), "pane ledgers")
  end

  test "right column wraps long MCP and activity lines instead of ellipsizing" do
    text =
      Tui.frame_lines(@live_frame, ["you> ooo interview"], "", 120, 34, %{
        interview_reasoning: [
          "next: ask user to answer pending question with a deliberately long status that must wrap inside the sidebar"
        ],
        mcp_activity: [
          "activity: round 1 · question: \"Which exact right panel surface should show the internal MCP reasoning and activity stream for the user?\""
        ]
      })
      |> Enum.join("\n")

    assert text =~ "must"
    assert text =~ "status that must wrap inside the"
    assert text =~ "exact right panel surface should"
    assert text =~ "show the internal MCP reasoning and"
    assert text =~ "activity stream for the user?"
    assert text =~ "user?\""
    refute text =~ "..."
  end

  test "active interview owns the left panel instead of duplicating activity below it" do
    block =
      {"INTERVIEW",
       [
         {"Question  Which work should happen first?", :warn},
         {"Answer  Refactor/cleanup", :strong},
         {"Question  What does cleanup mean here?", :warn}
       ], "plain answer"}

    text =
      Tui.frame_lines(
        @live_frame,
        [
          "[workflow-starting] dispatching_input task=task_1",
          "task: queued task_1: ooo interview",
          "you> Refactor/cleanup",
          "you> General hygiene",
          "workflow resumed"
        ],
        "",
        100,
        24,
        %{
          interview_block: block,
          interview_reasoning: ["waiting for your answer"],
          interview_paused: false
        }
      )
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ "Question Which work should happen first?"
    assert text =~ "Answer Refactor/cleanup"
    refute text =~ "MCP parent"

    refute text =~ "workflow-starting"
    refute text =~ "task: queued"
    refute text =~ "you> Refactor/cleanup"
    refute text =~ "you> General hygiene"
    refute text =~ "workflow resumed"
  end

  test "router ASK_USER protocol is not shown in the interview activity line" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{router: ["ASK_USER (4 opt): What should change next?"]},
          paused: false
        }
      end
    }

    assert [activity] = Tui.interview_working_lines(result, 0)
    assert activity =~ "question ready"
    refute activity =~ "ASK_USER"
    refute activity =~ "4 opt"
  end

  defp line_index(lines, pattern) do
    Enum.find_index(lines, &String.contains?(&1, pattern))
  end

  test "the activity line animates and stays clean before a question arrives" do
    result = %{pane_snapshot: fn -> %{interview: %{}, paused: false} end}

    a = Tui.interview_working_lines(result, 0)
    b = Tui.interview_working_lines(result, 1)

    assert [line_a] = a
    assert [line_b] = b
    assert line_a =~ "■⬝⬝ building the first question"
    assert line_b =~ "■■⬝ building the first question"
    assert line_a != line_b
  end

  test "right interview status shows a visible spinner while waiting on MCP" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{waiting: true, status: "waiting for MCP interview question"},
          paused: false
        }
      end
    }

    assert ["■⬝⬝ step received - preparing the interview question"] =
             Tui.interview_reasoning_lines(result, 0)

    assert ["■■⬝ step received - preparing the interview question"] =
             Tui.interview_reasoning_lines(result, 1)
  end

  test "a paused interview shows no spinner (the user is talking to main)" do
    result = %{pane_snapshot: fn -> %{interview: %{question: "q?"}, paused: true} end}
    assert Tui.interview_working_lines(result, 3) == []
  end

  test "right interview status does not keep spinning while paused" do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{waiting: true, status: "waiting for MCP follow-up question"},
          paused: true
        }
      end
    }

    assert ["step paused - discussing with main session"] =
             Tui.interview_reasoning_lines(result, 0)

    assert ["step paused - discussing with main session"] =
             Tui.interview_reasoning_lines(result, 1)
  end

  test "paused interview explains how to submit a direct answer" do
    block =
      {"INTERVIEW (paused)",
       [
         "Interview",
         "What should change?"
       ], "type to talk to main   /answer <answer> submits to interview"}

    text =
      Tui.frame_lines(@live_frame, ["you> discuss first"], "", 100, 24, %{
        interview_block: block,
        interview_paused: true
      })
      |> Enum.join("\n")

    assert text =~ "/answer <text> resumes"
    assert text =~ "type normally to discuss"
  end

  test "paused interview hides command palette when cancel is ready to submit" do
    block =
      {"INTERVIEW (paused)",
       [
         "Interview",
         "What should change?"
       ], "type to talk to main   /answer <answer> submits to interview"}

    text =
      Tui.frame_lines(@live_frame, ["you> discuss first"], "/cancel", 100, 24, %{
        mode: :palette,
        interview_block: block,
        interview_paused: true,
        palette: %{
          entries: [
            %{slash: "/cancel", summary: "Stop the paused interview"},
            %{slash: "/commands", summary: "Open commands"}
          ],
          index: 0
        }
      })
      |> Enum.join("\n")

    assert text =~ "INTERVIEW (paused)"
    assert text =~ "> /cancel"
    refute text =~ "+- commands"
    refute text =~ "selected /cancel"
  end

  test "paused interview transcript keeps the discussion near the checkpoint" do
    block =
      {"INTERVIEW (paused)", ["Interview", "What should change?"],
       "type to talk to main   /answer <answer> submits to interview"}

    text =
      Tui.frame_lines(
        @live_frame,
        [
          "empty",
          "[workflow-starting] dispatching_input task=task_1",
          "task: queued task_1: ooo interview",
          "-- interview paused (type normally to discuss; /answer <text> resumes)",
          "-- model: codex",
          "status=healthy runtime=ready",
          "you> discuss this first",
          "ourocode> I will discuss it before answering.",
          "workflow resumed"
        ],
        "",
        100,
        24,
        %{
          interview_block: block,
          interview_paused: true
        }
      )
      |> Enum.join("\n")

    assert text =~ "discuss this first"
    assert text =~ "I will discuss it before answering"
    refute text =~ "workflow-starting"
    refute text =~ "task: queued"
    refute text =~ "interview paused (type to talk"
    refute text =~ "-- empty"
    refute text =~ "model: codex"
    refute text =~ "status=healthy"
    refute text =~ "workflow resumed"
  end

  test "the three-party dialogue is color-coded per speaker" do
    # Stored newest-first (as LoopBindings keeps it).
    dialogue = [
      %{role: :main, text: "[from-code] Elixir escript"},
      %{role: :mcp, text: "(ambiguity 0.42) which stack?"}
    ]

    result = %{pane_snapshot: fn -> %{interview: %{dialogue: dialogue}, paused: false} end}

    rows = Tui.dialogue_rows(result, false)

    # Oldest -> newest, each carrying an explicit speaker color.
    assert [{mcp_line, :warn}, :rule, {main_line, :ok}] = rows
    assert mcp_line == "Question  (ambiguity 0.42) which stack?"
    assert main_line == "MAIN  [from-code] Elixir escript"
  end

  test "restored string-keyed question owns the left interview decision surface" do
    result = %{
      pane_snapshot: fn ->
        %{
          "interview" => %{
            "dialogue" => [
              %{"role" => "user", "text" => "seed/run/evaluate/evolve execution flow"},
              %{"role" => "user", "text" => "progress visibility"}
            ],
            "question" =>
              "For progress visibility, should the interview clarify current step names, done criteria, or failure causes first?",
            "status" => "waiting for your answer"
          },
          "paused" => false
        }
      end
    }

    block = InterviewPanel.interview_block_lines(result, nil, 0)

    text =
      Tui.frame_lines(
        @live_frame,
        [
          "[workflow-starting] dispatching_input task=task_1",
          "task: queued task_1: ooo interview ourocode",
          "you> seed/run/evaluate/evolve execution flow"
        ],
        "",
        100,
        24,
        %{
          interview_block: block,
          interview_reasoning: Tui.interview_reasoning_lines(result),
          interview_paused: false
        }
      )
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ "current step names"
    assert text =~ "done criteria"
    assert text =~ "failure causes first"
    refute text =~ "Answer seed/run/evaluate/evolve execution flow"
    refute text =~ "Answer progress visibility"
    refute text =~ "workflow-starting"
    refute text =~ "task: queued"
    refute text =~ "you> seed/run/evaluate"
  end

  test "internal router prompts are hidden from the dialogue transcript" do
    leaked = """
    [from-code]. Describe what exists; never prescribe what a new feature should do.
    Tool protocol - emit ONE directive as the first line, nothing before it:
      ANSWER [from-code] <answer>
      ASK_USER <question for the human>
    Output exactly one directive as the first line.
    """

    dialogue = [
      %{role: :main, text: leaked},
      %{role: :mcp, text: "What change should this interview define?"}
    ]

    result = %{pane_snapshot: fn -> %{interview: %{dialogue: dialogue}, paused: false} end}

    rows = Tui.dialogue_rows(result, false)

    assert [{mcp_line, :warn}] = rows
    assert mcp_line == "Question  What change should this interview define?"
  end

  test "the open MCP question is dropped from history when the picker shows it" do
    dialogue = [
      %{role: :mcp, text: "(ambiguity 0.7) pick transport?"},
      %{role: :user, text: "stdio"},
      %{role: :mcp, text: "(ambiguity 0.5) earlier q"}
    ]

    result = %{pane_snapshot: fn -> %{interview: %{dialogue: dialogue}, paused: false} end}

    # drop_trailing_mcp?: the newest turn is :mcp (the open question the
    # picker renders), so it is not duplicated in the history rows.
    assert [{_q, :warn}, :rule, {you, :strong}] = Tui.dialogue_rows(result, true)
    assert you == "Answer  stdio"

    refute Tui.dialogue_rows(result, true)
           |> Enum.any?(fn
             {t, _style} -> t =~ "pick transport?"
             :rule -> false
           end)

    # Without the drop it stays (plain/waiting state keeps the open question).
    assert Tui.dialogue_rows(result, false) |> List.last() |> elem(0) =~ "pick transport?"
  end

  test "interview transcript separates chat turns without heavy horizontal rules" do
    dialogue = [
      %{role: :mcp, text: "Which user segment matters first?"},
      %{role: :user, text: "Developers already using coding agents"}
    ]

    block =
      {"INTERVIEW",
       Tui.dialogue_rows(%{pane_snapshot: fn -> %{interview: %{dialogue: dialogue}} end}, false),
       "plain answer"}

    text =
      Tui.frame_lines(@live_frame, [], "", 100, 24, %{interview_block: block})
      |> Enum.join("\n")

    assert text =~ "Question Which user segment matters first?"
    assert text =~ "Answer Developers already using coding agents"
    refute text =~ "Question Question"
  end

  test "interview preparation status is separated from chat turns" do
    dialogue = [
      %{role: :user, text: "ooo interview improve onboarding"},
      %{role: :mcp, text: "Which onboarding moment is rough?"}
    ]

    result =
      %{pane_snapshot: fn -> %{interview: %{dialogue: dialogue, router: []}, paused: false} end}

    block =
      {"INTERVIEW",
       Tui.dialogue_rows(result, false) ++ [:rule | Tui.interview_working_lines(result, 0)],
       "plain answer"}

    text =
      Tui.frame_lines(@live_frame, [], "", 100, 24, %{interview_block: block})
      |> Enum.join("\n")

    assert text =~ "Question Which onboarding moment is rough?"
    assert text =~ "■⬝⬝ building the first question"
    refute text =~ "Question Question"
  end

  test "wonder focus without a block falls back to the transcript instead of blanking" do
    text =
      Tui.frame_lines(
        @live_frame,
        ["you> ooo interview improve onboarding", "ourocode> starting interview"],
        "",
        100,
        24,
        %{wonder_focus: true}
      )
      |> Enum.join("\n")

    assert text =~ "ooo interview improve onboarding"
    assert text =~ "starting interview"
  end

  test "scroll-back keeps older transcript reachable without truncation" do
    history = for n <- 1..40, do: "ourocode> line-#{n}"

    tail = render(@idle_frame, history, 0)
    assert tail =~ "line-40"
    refute tail =~ "line-1"

    # A large offset clamps to the top of history (full scroll-back).
    scrolled = render(@idle_frame, history, 1000)
    assert scrolled =~ "line-1"
  end
end
