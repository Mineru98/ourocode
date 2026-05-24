defmodule Ourocode.Terminal.TuiFrameStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{Layout, SessionListPane, TaskPromptInput}
  alias Ourocode.Terminal.{Screen, TuiFrame, TuiState}

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
            mcp_reasoning: ["phase: question", "pending: waiting for your answer"]
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
    assert text =~ "Free answer for this interview checkpoint"
  end
end
