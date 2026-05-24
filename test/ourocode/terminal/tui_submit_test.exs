defmodule Ourocode.Terminal.TuiSubmitTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiState, TuiSubmit}

  setup do
    {:ok, output} = StringIO.open("")
    IO.write(output, "existing output\n")
    state = TuiState.start_link()

    on_exit(fn ->
      safe_close(output, &StringIO.close/1)
      safe_close(state, &Agent.stop/1)
    end)

    %{output: output, state: state}
  end

  test "handle opens model picker for model commands", %{output: output, state: state} do
    callbacks = callbacks(self())

    assert :continue = TuiSubmit.handle("/model", %{}, output, state, 80, 24, callbacks)
    assert TuiState.mode(state) == :model
    assert TuiState.pidx(state) == 0
    assert_receive {:redraw, "", 80, 24}
  end

  test "handle returns slash and ooo submissions without chatting", %{
    output: output,
    state: state
  } do
    callbacks = callbacks(self())

    assert {:submit, "/status"} =
             TuiSubmit.handle("/status", %{}, output, state, 80, 24, callbacks)

    assert {:submit, "ooo run seed.md"} =
             TuiSubmit.handle("ooo run seed.md", %{}, output, state, 80, 24, callbacks)

    assert_receive {:redraw, "", 80, 24}
  end

  test "handle clears captured output and redraws", %{output: output, state: state} do
    callbacks = callbacks(self())

    assert :continue = TuiSubmit.handle("/clear", %{}, output, state, 80, 24, callbacks)
    assert StringIO.contents(output) == {"", ""}
    assert_receive {:redraw, "", 80, 24}
  end

  test "handle exits on quit commands", %{output: output, state: state} do
    callbacks = callbacks(self())

    assert :exit = TuiSubmit.handle("/exit", %{}, output, state, 80, 24, callbacks)
    assert :exit = TuiSubmit.handle("/quit", %{}, output, state, 80, 24, callbacks)
  end

  defp callbacks(parent) do
    [
      active_model: fn _state -> nil end,
      redraw: fn _result, _output, _state, prompt, cols, rows ->
        send(parent, {:redraw, prompt, cols, rows})
        :ok
      end
    ]
  end

  defp safe_close(pid, close) when is_pid(pid) and is_function(close, 1) do
    if Process.alive?(pid), do: close.(pid)
    :ok
  catch
    :exit, _reason -> :ok
  end
end
