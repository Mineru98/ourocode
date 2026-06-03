defmodule Ourocode.Terminal.TuiFrameStateTest do
  use ExUnit.Case, async: false

  alias Ourocode.Dashboard.{
    ChildSessionPanes,
    Layout,
    ParentMcpPane,
    SessionListPane,
    TaskPromptInput
  }

  alias Ourocode.Terminal.{
    InterviewPanel.QuestionLedger,
    Screen,
    ScreenStyles,
    TuiFrame,
    TuiState
  }

  test "view_opts projects mutable TUI state into renderer options" do
    state = TuiState.start_link()

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    TuiState.put_mode(state, :palette)
    TuiState.put_pidx(state, 2)
    TuiState.toggle_key_help(state)
    TuiState.set_streaming(state, true)

    opts =
      TuiFrame.view_opts(state,
        auth_label: fn ^state -> "gpt-5" end,
        test_run?: fn -> true end
      )

    assert opts.mode == :palette
    assert opts.auth == "gpt-5"
    assert opts.streaming == true
    assert opts.key_help == true
    assert opts.pidx == 2
    assert is_map(opts.palette)
    assert opts.model == nil
    assert is_list(opts.file_mentions)
  end

  test "redraw ignores previous screen cache when the theme changes" do
    state = TuiState.start_link()

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    TuiState.put_prev_screen(state, :previous_screen)
    TuiState.put_render_theme(state, :dark)

    assert TuiFrame.previous_screen_for_theme(state, :dark) == :previous_screen
    assert TuiFrame.previous_screen_for_theme(state, :light) == nil
  end

  test "redraw fully repaints with light styles after a dark render" do
    previous_theme = System.get_env("OUROCODE_THEME")
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      restore_theme(previous_theme)

      if Process.alive?(state), do: Agent.stop(state)
    end)

    result = minimal_result()

    System.put_env("OUROCODE_THEME", "dark")

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 80, 20,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    assert TuiState.render_theme(state) == :dark
    System.put_env("OUROCODE_THEME", "light")

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 80, 20,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    rendered =
      state
      |> TuiState.prev_screen()
      |> Screen.to_ansi()
      |> IO.iodata_to_binary()

    assert TuiState.render_theme(state) == :light
    assert rendered =~ ScreenStyles.sgr(:text, :light)
    refute rendered =~ ScreenStyles.sgr(:text, :dark)
  end

  test "redraw keeps the active interview question visible when wonder request is incomplete" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    question = "Round 2: which plugin behavior should we verify manually?"

    result = %{
      status: :healthy,
      context: %{},
      panes:
        Layout.apply_compact_session_list_layout(%{
          working: SessionListPane.render([]),
          completed: SessionListPane.render_completed([]),
          task_prompt: TaskPromptInput.render()
        }),
      pane_snapshot: fn ->
        %{
          wonder_tool: %{request_id: "wt-incomplete", request: %{"questions" => []}},
          interview: %{
            question: question,
            status: "waiting for your answer",
            mcp_reasoning: ["step: question", "pending: waiting for your answer"]
          },
          paused: false
        }
      end
    }

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 100, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text =
      state
      |> TuiState.prev_screen()
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ question
    assert text =~ "Enter confirm"
  end

  test "redraw renders a session-state question even without dialogue history" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    question =
      "When ourocode is widely used, which first user outcome should the interview clarify?"

    result = %{
      status: :healthy,
      context: %{},
      panes:
        Layout.apply_compact_session_list_layout(%{
          working: SessionListPane.render([]),
          completed: SessionListPane.render_completed([]),
          task_prompt: TaskPromptInput.render()
        }),
      pane_snapshot: fn ->
        %{
          "interview" => %{
            "question" => question,
            "status" => "waiting for your answer",
            "mcp_reasoning" => ["step: question", "source: session_state"]
          },
          "paused" => false
        }
      end
    }

    assert :ok =
             TuiFrame.redraw(
               result,
               output,
               state,
               "",
               100,
               24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text =
      state
      |> TuiState.prev_screen()
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ "When ourocode is widely used"
    assert text =~ "should the interview clarify?"
    refute text =~ "workflow-starting"
  end

  test "redraw stores exact visible hit targets for interview ledger rows" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    result =
      minimal_result()
      |> Map.put(:pane_snapshot, fn ->
        %{
          interview: %{
            dialogue: [
              %{role: :user, text: "Second answer"},
              %{role: :mcp, text: "Second question"},
              %{role: :user, text: "First answer"},
              %{role: :mcp, text: "First question"}
            ]
          },
          paused: false
        }
      end)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 100, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    screen_lines = state |> TuiState.prev_screen() |> Screen.to_lines()
    hit_map = TuiState.interview_ledger_hit_map(state)

    blocks =
      result
      |> pane_interview()
      |> QuestionLedger.from_interview()
      |> Map.fetch!(:blocks)

    first = Enum.at(blocks, 0)
    second = Enum.at(blocks, 1)
    q1_row = visible_row(screen_lines, "Q1 First question") + 1
    q2_row = visible_row(screen_lines, "Q2 Second question") + 1

    assert hit_map[q1_row].id == first.id
    assert hit_map[q2_row].id == second.id
    assert hit_map[q1_row].x1 == 1
    assert hit_map[q1_row].x2 == 100
  end

  test "redraw maps wrapped ledger rows to the same block id" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    long_question =
      "아주 긴 질문입니다. transformer baseline 없이도 성능이 유지되는지 확인하기 위해 합성 데이터 패턴과 규칙 기반 시퀀스 변환을 비교하는 기준을 어떻게 둘까요?"

    result =
      minimal_result()
      |> Map.put(:pane_snapshot, fn ->
        %{
          interview: %{
            dialogue: [
              %{role: :user, text: "정확도 기준"},
              %{role: :mcp, text: long_question}
            ]
          },
          paused: false
        }
      end)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 54, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    hit_map = TuiState.interview_ledger_hit_map(state)

    block_id =
      result
      |> pane_interview()
      |> QuestionLedger.from_interview()
      |> Map.fetch!(:blocks)
      |> List.first()
      |> Map.fetch!(:id)

    rows =
      hit_map |> Enum.filter(fn {_row, hit} -> hit.id == block_id end) |> Enum.map(&elem(&1, 0))

    assert length(rows) >= 2
    assert Enum.all?(rows, &(hit_map[&1].id == block_id))
  end

  test "redraw uses selected ledger state to open the clicked question detail" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    result =
      minimal_result()
      |> Map.put(:pane_snapshot, fn ->
        %{
          interview: %{
            dialogue: [
              %{role: :user, text: "Second answer"},
              %{role: :main, text: "second reasoning"},
              %{role: :mcp, text: "Second question"},
              %{role: :user, text: "First answer"},
              %{role: :main, text: "first reasoning"},
              %{role: :mcp, text: "First question"}
            ]
          },
          paused: false
        }
      end)

    first_id =
      result
      |> pane_interview()
      |> QuestionLedger.from_interview()
      |> Map.fetch!(:blocks)
      |> List.first()
      |> Map.fetch!(:id)

    TuiState.put_interview_ledger_selected_id(state, first_id)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 100, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text = state |> TuiState.prev_screen() |> Screen.to_lines() |> Enum.join("\n")

    assert text =~ "- [answered] Q1 First question"
    assert text =~ "Answer First answer"
    assert text =~ "Reason first reasoning"
    assert text =~ "+ [answered] Q2 Second question"
    refute text =~ "Answer Second answer"
  end

  test "redraw opens a clicked older question during accepted-round transition" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    interview = %{
      waiting: true,
      status: "preparing next interview question",
      question: "",
      last_answered_question: "Third question",
      last_answer: "Third answer",
      dialogue: [
        %{role: :user, text: "Second answer"},
        %{role: :mcp, text: "Second question"},
        %{role: :user, text: "First answer"},
        %{role: :mcp, text: "First question"}
      ]
    }

    second_id =
      interview
      |> QuestionLedger.from_interview()
      |> Map.fetch!(:blocks)
      |> Enum.at(1)
      |> Map.fetch!(:id)

    TuiState.put_interview_ledger_selected_id(state, second_id)

    result =
      minimal_result()
      |> Map.put(:pane_snapshot, fn ->
        %{
          interview: interview,
          paused: false
        }
      end)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 120, 28,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text = state |> TuiState.prev_screen() |> Screen.to_lines() |> Enum.join("\n")

    assert text =~ "+ [answered] Q1 First question"
    assert text =~ "- [answered] Q2 Second question"
    assert text =~ "Answer Second answer"
    assert text =~ "+ [generating] Q3 Third question"
    assert text =~ "Round accepted"
    refute text =~ "Answer First answer"
  end

  test "redraw clears stale ledger hit targets when workspace hides the interview" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    TuiState.put_interview_ledger_hit_map(state, %{9 => %{id: "old", x1: 1, x2: 100}})
    TuiState.put_workspace(state, %{kind: "status", title: "Status", records: []})

    assert :ok =
             TuiFrame.redraw(minimal_result(), output, state, "", 100, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    assert TuiState.interview_ledger_hit_map(state) == %{}
  end

  test "redraw stores MCP tool ledger hit targets and opens selected detail" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    result =
      minimal_result()
      |> Map.put(:pane_snapshot, fn ->
        %{
          runtime: mcp_runtime_snapshot(),
          paused: false
        }
      end)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 120, 30,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text = state |> TuiState.prev_screen() |> Screen.to_lines() |> Enum.join("\n")
    assert text =~ "pane ledgers"
    assert text =~ "+ [completed] Tool ouroboros__qa QA"
    assert text =~ "passed"

    hit_map = TuiState.mcp_ledger_hit_map(state)
    assert [{_row, %{id: block_id}} | _rest] = Enum.sort(hit_map)

    TuiState.put_mcp_ledger_selected_id(state, block_id)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 120, 30,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text = state |> TuiState.prev_screen() |> Screen.to_lines() |> Enum.join("\n")
    assert text =~ "- [completed] Tool ouroboros__qa QA"
    assert text =~ "payload"
  end

  test "redraw clears live turn feedback once an interview owns the surface" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    TuiState.put_live_turn_event(state, %{
      prompt_state: :awaiting_prompt,
      task_input: "ooo pm verify live feedback"
    })

    assert :ok =
             TuiFrame.redraw(minimal_result(), output, state, "", 100, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    opening_text =
      state
      |> TuiState.prev_screen()
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert opening_text =~ "live: PM interview is opening"
    assert TuiState.live_turn_event(state) != nil

    result =
      minimal_result()
      |> Map.put(:pane_snapshot, fn ->
        %{
          interview: %{
            question: "Which launch outcome should this PM flow clarify?",
            status: "waiting for your answer",
            question_options: [
              %{label: "Adoption", description: "Focus on activation first"}
            ]
          },
          paused: false
        }
      end)

    assert :ok =
             TuiFrame.redraw(result, output, state, "", 100, 24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    question_text =
      state
      |> TuiState.prev_screen()
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert question_text =~ "Which launch outcome should this PM flow clarify?"
    refute question_text =~ "live: PM interview is opening"
    assert TuiState.live_turn_event(state) == nil
  end

  test "redraw renders stored interview options instead of a free-answer-only checkpoint" do
    state = TuiState.start_link()
    {:ok, output} = StringIO.open("")

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    result = %{
      status: :healthy,
      context: %{},
      panes:
        Layout.apply_compact_session_list_layout(%{
          working: SessionListPane.render([]),
          completed: SessionListPane.render_completed([]),
          task_prompt: TaskPromptInput.render()
        }),
      pane_snapshot: fn ->
        %{
          "interview" => %{
            "question" => "Which outcome should be optimized first?",
            "question_options" => [
              %{"label" => "Quality", "description" => "Raise reliability first"},
              %{"label" => "Speed", "description" => "Optimize turnaround first"}
            ],
            "status" => "waiting for your answer"
          },
          "paused" => false
        }
      end
    }

    assert :ok =
             TuiFrame.redraw(
               result,
               output,
               state,
               "",
               100,
               24,
               auth_label: fn ^state -> {"", :dim} end,
               test_run?: fn -> true end
             )

    text =
      state
      |> TuiState.prev_screen()
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "Which outcome should be optimized first?"
    assert text =~ ">> [1] Quality - Raise reliability first"
    assert text =~ "[2] Speed - Optimize turnaround first"
    refute text =~ "question ready"
  end

  defp minimal_result do
    %{
      status: :healthy,
      context: %{},
      panes:
        Layout.apply_compact_session_list_layout(%{
          working: SessionListPane.render([]),
          completed: SessionListPane.render_completed([]),
          task_prompt: TaskPromptInput.render()
        })
    }
  end

  defp pane_interview(%{pane_snapshot: snapshot}) when is_function(snapshot, 0) do
    snapshot.().interview
  end

  defp mcp_runtime_snapshot do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :stdio,
        parent_call_id: "parent-frame-ledger-1",
        runtime_source: "mcp",
        external_ids: %{},
        occurred_at_ms: 100,
        request_id: "call-frame-ledger-1",
        method: "tools/call",
        params: %{"name" => "ouroboros__ralph"}
      })

    {:ok, child_state} =
      %{working: [], completed: [], focused: nil, open: []}
      |> ChildSessionPanes.register_child_pane(%{
        child_id: "session-frame-a",
        parent_call_id: "parent-frame-ledger-1",
        runtime_source: "ouroboros",
        transport: :stdio,
        stream_cursor: %{event_seq: 2},
        pane_state: %{
          stream_entries: [
            %{
              event_seq: 2,
              runtime_seq: 1,
              payload: %{
                "tool_call_id" => "tool-frame-a",
                "tool_name" => "ouroboros__qa",
                "status" => "completed",
                "result" => "QA passed",
                "arguments" => %{"session_id" => "session-frame-a"}
              }
            }
          ]
        }
      })

    %{
      parent_panes: parent_state,
      child_panes: child_state,
      mcp_topology: %{}
    }
  end

  defp visible_row(lines, needle) do
    Enum.find_index(lines, &String.contains?(&1, needle)) ||
      raise "expected visible row containing #{inspect(needle)}"
  end

  defp restore_theme(nil), do: System.delete_env("OUROCODE_THEME")
  defp restore_theme(theme), do: System.put_env("OUROCODE_THEME", theme)
end
