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
end
