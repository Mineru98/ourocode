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
