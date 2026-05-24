defmodule Ourocode.Terminal.TuiNormalEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiNormalEvent, TuiState}

  setup do
    state = TuiState.start_link()
    Agent.update(state, &%{&1 | buffer: "", cursor: 0, mode: :normal, pidx: 0})

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    %{state: state}
  end

  test "ctrl-d exits only when the composer is empty", %{state: state} do
    assert TuiNormalEvent.handle(%{key: :ctrl_d}, state, callbacks()) == :exit

    TuiState.edit_buffer(state, %{key: :char, char: "x"})

    assert TuiNormalEvent.handle(%{key: :ctrl_d}, state, callbacks()) == :continue
    assert TuiState.buffer(state) == "x"
  end

  test "char input edits buffer and redraws", %{state: state} do
    parent = self()

    assert TuiNormalEvent.handle(%{key: :char, char: "a"}, state, callbacks(parent)) ==
             :continue

    assert TuiState.buffer(state) == "a"
    assert_received :draw
  end

  test "enter submits trimmed buffer, clears composer, and remembers history", %{state: state} do
    parent = self()
    TuiState.edit_buffer(state, %{key: :paste, char: "  hello  "})

    assert TuiNormalEvent.handle(%{key: :enter}, state, callbacks(parent)) == :continue

    assert TuiState.buffer(state) == ""
    assert_received {:entered, "hello"}

    TuiState.move_history(state, -1)
    assert TuiState.buffer(state) == "hello"
  end

  test "page keys adjust scroll and redraw", %{state: state} do
    parent = self()

    assert TuiNormalEvent.handle(%{key: :page_up}, state, callbacks(parent)) == :continue
    assert_received :draw

    assert TuiNormalEvent.handle(%{key: :page_down}, state, callbacks(parent)) == :continue
    assert_received :draw
  end

  defp callbacks(parent \\ self()) do
    %{
      choose_model: fn -> send(parent, :choose_model) end,
      cont: fn -> :continue end,
      draw: fn -> send(parent, :draw) end,
      handle_enter: fn line ->
        send(parent, {:entered, line})
        :continue
      end,
      test_run?: fn -> true end
    }
  end
end
