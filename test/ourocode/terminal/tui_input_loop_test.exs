defmodule Ourocode.Terminal.TuiInputLoopTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.{TuiInputLoop, TuiState}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-tui-input-loop-#{System.unique_integer([:positive])}"
      )

    previous = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", dir)

    {:ok, output} = StringIO.open("")
    state = TuiState.start_link()
    parent = self()

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_STATE_DIR", previous),
        else: System.delete_env("OUROCODE_STATE_DIR")

      if Process.alive?(state), do: Agent.stop(state)
      File.rm_rf!(dir)
    end)

    %{callbacks: callbacks(parent), output: output, state: state}
  end

  test "char input edits the composer and redraws", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "a"}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.buffer(state) == "a"
    assert_received {:redraw, "a", 80, 24}
  end

  test "consecutive plain keystrokes coalesce into a single composer redraw", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    events = for c <- ["h", "e", "l", "l", "o"], do: %{key: :char, char: c}

    assert TuiInputLoop.handle_events(events, %{}, output, state, 80, 24, callbacks) ==
             :continue

    assert TuiState.buffer(state) == "hello"
    # The burst edits and redraws once with the final buffer, not once per char.
    assert_received {:redraw, "hello", 80, 24}
    refute_received {:redraw, "h", 80, 24}
    refute_received {:redraw, "hel", 80, 24}
  end

  test "a fast multi-byte keystroke burst coalesces without losing graphemes", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    events = for c <- ["안", "녕", "🚀", "a", "字"], do: %{key: :char, char: c}

    assert TuiInputLoop.handle_events(events, %{}, output, state, 80, 24, callbacks) ==
             :continue

    assert TuiState.buffer(state) == "안녕🚀a字"
    assert String.length(TuiState.buffer(state)) == 5
    assert_received {:redraw, "안녕🚀a字", 80, 24}
  end

  test "a slash within a keystroke run is not coalesced into the leading text", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    events = [
      %{key: :char, char: "a"},
      %{key: :char, char: "b"},
      %{key: :char, char: "/"}
    ]

    assert TuiInputLoop.handle_events(events, %{}, output, state, 80, 24, callbacks) ==
             :continue

    assert TuiState.buffer(state) == "ab/"
    # Events are applied in order while the redraw is deferred to the batch end.
    assert_received {:redraw, "ab/", 80, 24}
    refute_received {:redraw, "ab", 80, 24}
  end

  test "read loop drains fragmented queued chunks before one redraw", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    Process.put(:tui_input_loop_poll, nil)

    {:ok, chunks} =
      Agent.start_link(fn ->
        [
          "a",
          "e",
          <<0xCC>>,
          <<0x81>>,
          <<0xEC>>,
          <<0x95, 0x88>>,
          <<0xF0, 0x9F>>,
          <<0x91, 0xA9, 0xE2>>,
          <<0x80, 0x8D, 0xF0, 0x9F, 0x92, 0xBB>>,
          "\e",
          "[",
          "D",
          "x",
          <<127>>,
          :eof
        ]
      end)

    callbacks =
      callbacks
      |> Map.put(:next_chunk, fn _state, poll_ms ->
        Agent.get_and_update(chunks, fn
          [:eof | rest] ->
            assert poll_ms == Process.get(:tui_input_loop_poll)
            Process.put(:tui_input_loop_poll, 0)
            {:eof, rest}

          [chunk | rest] ->
            assert poll_ms == Process.get(:tui_input_loop_poll)
            Process.put(:tui_input_loop_poll, 0)
            {{:ok, chunk}, rest}

          [] ->
            assert poll_ms == Process.get(:tui_input_loop_poll)
            Process.put(:tui_input_loop_poll, 0)
            {:eof, []}
        end)
      end)
      |> Map.update!(:redraw, fn redraw ->
        fn result, output, state, prompt_buffer, columns, rows ->
          Process.sleep(1)
          redraw.(result, output, state, prompt_buffer, columns, rows)
        end
      end)

    assert TuiInputLoop.read_line(%{}, output, state, callbacks) == :eof
    assert TuiState.buffer(state) == "aé안👩‍💻"
    assert TuiState.cursor(state) == 3

    assert_received {:redraw, "", 120, 40}
    assert_received {:redraw, "aé안👩‍💻", 120, 40}
    refute_received {:redraw, _, 120, 40}
  end

  test "read loop batches more than 64 queued one-byte chunks", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    {:ok, chunks} = Agent.start_link(fn -> List.duplicate("x", 65) ++ [:eof] end)
    expected = String.duplicate("x", 65)

    callbacks =
      Map.put(callbacks, :next_chunk, fn _state, poll_ms ->
        Agent.get_and_update(chunks, fn
          [:eof | rest] ->
            assert poll_ms == 0
            {:eof, rest}

          [chunk | rest] ->
            assert poll_ms == 0 or poll_ms == nil
            {{:ok, chunk}, rest}
        end)
      end)

    assert TuiInputLoop.read_line(%{}, output, state, callbacks) == :eof
    assert TuiState.buffer(state) == expected
    assert_received {:redraw, ^expected, 120, 40}
  end

  test "input crossing the drain byte budget is rebuffered and resumed losslessly", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    combining_payload = "a" <> String.duplicate("\u0301", 524_284)
    first_chunk = "\e[200~" <> combining_payload
    expected = combining_payload <> "b]"

    assert byte_size(first_chunk) == 1_048_575

    {:ok, chunks} = Agent.start_link(fn -> [first_chunk, "b]", "\e[201~", :eof] end)

    callbacks =
      Map.put(callbacks, :next_chunk, fn _state, poll_ms ->
        Agent.get_and_update(chunks, fn
          [:eof | rest] ->
            assert poll_ms == 0
            {:eof, rest}

          [chunk | rest] ->
            assert poll_ms == 0 or poll_ms == nil
            {{:ok, chunk}, rest}
        end)
      end)

    assert TuiInputLoop.read_line(%{}, output, state, callbacks) == :eof
    assert TuiState.buffer(state) == expected
    assert_received {:redraw, ^expected, 120, 40}
  end

  test "split bracketed paste is decoded as one event before redraw", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    {:ok, chunks} =
      Agent.start_link(fn -> ["\e[20", "0~hello ", "안", "녕\e[20", "1~", :eof] end)

    callbacks =
      Map.put(callbacks, :next_chunk, fn _state, poll_ms ->
        Agent.get_and_update(chunks, fn
          [:eof | rest] ->
            {:eof, rest}

          [chunk | rest] ->
            assert poll_ms == 0 or poll_ms == nil
            {{:ok, chunk}, rest}
        end)
      end)

    assert TuiInputLoop.read_line(%{}, output, state, callbacks) == :eof
    assert TuiState.buffer(state) == "hello 안녕"
    assert_received {:redraw, "hello 안녕", 120, 40}
  end

  test "events after submit are preserved for the next read", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    {:ok, chunks} = Agent.start_link(fn -> ["first\nsecond", :eof] end)

    callbacks =
      Map.put(callbacks, :next_chunk, fn _state, poll_ms ->
        Agent.get_and_update(chunks, fn
          [:eof | rest] ->
            {:eof, rest}

          [chunk | rest] ->
            assert poll_ms == 0 or poll_ms == nil
            {{:ok, chunk}, rest}
        end)
      end)

    assert TuiInputLoop.read_line(%{}, output, state, callbacks) == "first"
    assert TuiState.buffer(state) == ""
    assert TuiInputLoop.read_line(%{}, output, state, callbacks) == :eof
    assert TuiState.buffer(state) == "second"
  end

  test "enter submits the trimmed composer line", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "  hello  "})

    assert TuiInputLoop.handle_events(
             [%{key: :enter}],
             %{},
             output,
             state,
             100,
             30,
             callbacks
           ) == {:submit, "hello"}

    assert TuiState.buffer(state) == ""
    assert_received {:handle_enter, "hello", 100, 30}
  end

  test "tab completes a partial ooo command", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "ooo int"})

    assert TuiInputLoop.handle_events(
             [%{key: :tab}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.buffer(state) == "ooo interview "
    assert_received {:redraw, "ooo interview ", 80, 24}
  end

  test "ctrl-c exits before later events are applied", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    assert TuiInputLoop.handle_events(
             [%{key: :ctrl_c}, %{key: :char, char: "x"}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :exit

    assert TuiState.buffer(state) == ""
  end

  test "tick flushes a buffered standalone escape immediately", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    parent = self()
    TuiState.put_leftover(state, <<27>>)

    result = %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: fn _payload -> {:ok, %{}} end,
      wonder_pause: fn -> send(parent, :paused) end
    }

    assert TuiInputLoop.handle_tick(result, output, state, 80, 24, callbacks) == :continue
    assert_received :paused
    assert TuiState.take_leftover(state) == ""
  end

  test "tick preserves incomplete escape sequences", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.put_leftover(state, <<27, ?[>>)

    assert TuiInputLoop.handle_tick(%{}, output, state, 80, 24, callbacks) == :continue
    assert TuiState.take_leftover(state) == <<27, ?[>>
  end

  test "slash input while forced paused stays in the composer", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.put_force_interview_paused(state, true)

    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "/"}],
             %{},
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.mode(state) == :normal
    assert TuiState.buffer(state) == "/"
    assert_received {:redraw, "/", 80, 24}
  end

  test "slash enter during an active interview dispatches the command instead of answering", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "/agents"})

    result = %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: fn _payload ->
        send(self(), :unexpected_answer)
        {:ok, %{}}
      end
    }

    assert TuiInputLoop.handle_events(
             [%{key: :enter}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == {:submit, "/agents"}

    assert_received {:handle_enter, "/agents", 80, 24}
    refute_received :unexpected_answer
  end

  test "ooo enter during an active interview dispatches the workflow instead of answering", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "ooo pm build onboarding"})

    result = %{
      pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end,
      wonder_answer: fn _payload ->
        send(self(), :unexpected_answer)
        {:ok, %{}}
      end
    }

    assert TuiInputLoop.handle_events(
             [%{key: :enter}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == {:submit, "ooo pm build onboarding"}

    assert_received {:handle_enter, "ooo pm build onboarding", 80, 24}
    refute_received :unexpected_answer
  end

  test "slash input during active interview stays in composer instead of opening palette", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    result = %{pane_snapshot: fn -> %{wonder_tool: detection(), paused: false} end}

    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "/"}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.mode(state) == :normal
    assert TuiState.buffer(state) == "/"
    refute_received {:redraw, "/", 80, 24}
  end

  test "arrow keys move plain interview options without mouse focus", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    result = %{
      pane_snapshot: fn ->
        %{
          interview: %{
            question: "Which email service first?",
            question_options: [
              %{label: "Gmail", description: "Google inboxes"},
              %{label: "Outlook", description: "Microsoft inboxes"}
            ]
          },
          paused: false
        }
      end
    }

    assert TuiInputLoop.handle_events(
             [%{key: :down}],
             result,
             output,
             state,
             80,
             24,
             callbacks
           ) == :continue

    assert TuiState.wonder_nav(state).picks == %{0 => 1}
    assert_received {:redraw, "", 80, 24}
  end

  test "MCP-only ledger keyboard navigation reaches interaction handler through input loop", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    first_id = "ledger:child:tool-call-1"
    second_id = "ledger:child:tool-call-2"

    TuiState.put_mcp_ledger_hit_map(state, %{
      12 => %{id: first_id, x1: 60, x2: 110},
      13 => %{id: second_id, x1: 60, x2: 110}
    })

    assert TuiInputLoop.handle_events(
             [%{key: :char, char: "1"}, %{key: :down}, %{key: :enter}],
             %{},
             output,
             state,
             100,
             30,
             callbacks
           ) == :continue

    assert TuiState.mcp_ledger_selected_id(state) == second_id
    assert hd(TuiState.notifications(state)) == "tool call opened"
    assert_received {:redraw, "", 100, 30}
  end

  test "MCP-only ledger input loop supports every advertised keyboard selector", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    ids = install_mcp_ledger_hit_map(state)

    steps = [
      {%{key: :char, char: "1"}, Enum.at(ids, 0)},
      {%{key: :char, char: "+"}, Enum.at(ids, 1)},
      {%{key: :char, char: "j"}, Enum.at(ids, 2)},
      {%{key: :char, char: "k"}, Enum.at(ids, 1)},
      {%{key: :down}, Enum.at(ids, 2)},
      {%{key: :up}, Enum.at(ids, 1)},
      {%{key: :char, char: "-"}, Enum.at(ids, 0)},
      {%{key: :char, char: "3"}, Enum.at(ids, 2)}
    ]

    Enum.each(steps, fn {event, expected_id} ->
      assert TuiInputLoop.handle_events([event], %{}, output, state, 100, 30, callbacks) ==
               :continue

      assert TuiState.mcp_ledger_selected_id(state) == expected_id
    end)

    assert TuiInputLoop.handle_events([%{key: :enter}], %{}, output, state, 100, 30, callbacks) ==
             :continue

    assert hd(TuiState.notifications(state)) == "tool call opened"

    Enum.each(1..9, fn number ->
      assert TuiInputLoop.handle_events(
               [%{key: :char, char: Integer.to_string(number)}],
               %{},
               output,
               state,
               100,
               30,
               callbacks
             ) == :continue

      assert TuiState.mcp_ledger_selected_id(state) == Enum.at(ids, number - 1)
    end)
  end

  test "tick does not redraw a pending cancel prefix during active interview", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "/canc"})
    result = %{pane_snapshot: fn -> %{interview: %{complete: false, status: "opening"}} end}

    assert TuiInputLoop.handle_tick(result, output, state, 80, 24, callbacks) == :continue

    refute_received {:redraw, "/canc", 80, 24}
  end

  test "tick redraws non-cancel slash input during active interview", %{
    callbacks: callbacks,
    output: output,
    state: state
  } do
    TuiState.edit_buffer(state, %{key: :paste, char: "/agents"})
    result = %{pane_snapshot: fn -> %{interview: %{complete: false, status: "opening"}} end}

    assert TuiInputLoop.handle_tick(result, output, state, 80, 24, callbacks) == :continue

    assert_received {:redraw, "/agents", 80, 24}
  end

  defp callbacks(parent) do
    %{
      choose_model: fn _result, _output, _state, columns, rows ->
        send(parent, {:choose_model, columns, rows})
        :ok
      end,
      handle_enter: fn line, _result, _output, _state, columns, rows ->
        send(parent, {:handle_enter, line, columns, rows})
        {:submit, line}
      end,
      redraw: fn _result, _output, state, _prompt_buffer, columns, rows ->
        send(parent, {:redraw, TuiState.buffer(state), columns, rows})
        :ok
      end,
      test_run?: fn -> true end
    }
  end

  defp install_mcp_ledger_hit_map(state) do
    ids = Enum.map(1..9, &"ledger:child:tool-call-#{&1}")

    hit_map =
      ids
      |> Enum.with_index(12)
      |> Map.new(fn {id, row} -> {row, %{id: id, x1: 60, x2: 110}} end)

    TuiState.put_mcp_ledger_hit_map(state, hit_map)
    ids
  end

  defp detection do
    %{
      request: %{
        tool: :wonder_tool,
        type: :multiple_choice_decision,
        questions: [
          %{
            id: "first",
            header: "First",
            question: "Pick one",
            options: [%{label: "a", description: "a description"}]
          }
        ]
      }
    }
  end
end
