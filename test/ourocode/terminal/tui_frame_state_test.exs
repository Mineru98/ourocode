defmodule Ourocode.Terminal.TuiFrameStateTest do
  use ExUnit.Case, async: false

  alias Ourocode.Dashboard.{Layout, SessionListPane, TaskPromptInput}
  alias Ourocode.Terminal.{Screen, ScreenStyles, TuiFrame, TuiState}

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

  defp restore_theme(nil), do: System.delete_env("OUROCODE_THEME")
  defp restore_theme(theme), do: System.put_env("OUROCODE_THEME", theme)
end
