defmodule Ourocode.Terminal.TuiNormalSubmitTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiNormalSubmit, TuiState}

  setup do
    state = TuiState.start_link()
    Agent.update(state, &%{&1 | buffer: "", cursor: 0, mode: :normal, pidx: 0})

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    %{state: state}
  end

  test "handle inserts selected file mention and keeps composer open", %{state: state} do
    parent = self()
    Agent.update(state, &%{&1 | buffer: "@lib", cursor: 4, file_cache: ["lib/a.ex"]})

    assert :continue = TuiNormalSubmit.handle(state, callbacks(parent), draw(parent), cont())
    assert TuiState.buffer(state) == "@lib/a.ex "
    assert TuiState.pidx(state) == 0
    assert_received :draw
    refute_received {:entered, _line}
  end

  test "handle submits selected ooo suggestion", %{state: state} do
    parent = self()
    Agent.update(state, &%{&1 | buffer: "ooo", cursor: 3, pidx: 1})

    assert :continue = TuiNormalSubmit.handle(state, callbacks(parent), draw(parent), cont())
    assert TuiState.buffer(state) == ""
    assert_received {:entered, line}
    assert line =~ "ooo "
  end

  test "handle trims normal input and remembers history", %{state: state} do
    parent = self()
    Agent.update(state, &%{&1 | buffer: "  hello  ", cursor: 9})

    assert :continue = TuiNormalSubmit.handle(state, callbacks(parent), draw(parent), cont())
    assert TuiState.buffer(state) == ""
    assert_received {:entered, "hello"}

    TuiState.move_history(state, -1)
    assert TuiState.buffer(state) == "hello"
  end

  test "handle propagates submit and exit callback results", %{state: state} do
    Agent.update(state, &%{&1 | buffer: "/status", cursor: 7})

    submit_callbacks =
      callbacks(self())
      |> Map.put(:handle_enter, fn line -> {:submit, line} end)

    assert {:submit, "/status"} = TuiNormalSubmit.handle(state, submit_callbacks, draw(), cont())

    Agent.update(state, &%{&1 | buffer: "/exit", cursor: 5})

    exit_callbacks =
      callbacks(self())
      |> Map.put(:handle_enter, fn _line -> :exit end)

    assert :exit = TuiNormalSubmit.handle(state, exit_callbacks, draw(), cont())
  end

  defp callbacks(parent) do
    %{
      handle_enter: fn line ->
        send(parent, {:entered, line})
        :continue
      end,
      test_run?: fn -> true end
    }
  end

  defp draw(parent \\ self()), do: fn -> send(parent, :draw) end
  defp cont, do: fn -> :continue end
end
