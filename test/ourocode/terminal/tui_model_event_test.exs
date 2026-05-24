defmodule Ourocode.Terminal.TuiModelEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiModelEvent, TuiState}

  setup do
    state = TuiState.start_link()
    TuiState.put_mode(state, :model)

    on_exit(fn ->
      try do
        if Process.alive?(state), do: Agent.stop(state)
      catch
        :exit, _reason -> :ok
      end
    end)

    %{state: state}
  end

  test "escape and backspace close model mode", %{state: state} do
    parent = self()

    assert :continue =
             TuiModelEvent.handle(%{key: :escape}, state, callbacks(parent), draw(parent), cont())

    assert TuiState.mode(state) == :normal
    assert_received :draw

    TuiState.put_mode(state, :model)

    assert :continue =
             TuiModelEvent.handle(
               %{key: :backspace},
               state,
               callbacks(parent),
               draw(parent),
               cont()
             )

    assert TuiState.mode(state) == :normal
  end

  test "up and down move model picker index", %{state: state} do
    parent = self()

    assert :continue =
             TuiModelEvent.handle(%{key: :down}, state, callbacks(parent), draw(parent), cont())

    assert TuiState.pidx(state) == 1

    assert :continue =
             TuiModelEvent.handle(%{key: :up}, state, callbacks(parent), draw(parent), cont())

    assert TuiState.pidx(state) == 0
  end

  test "enter delegates model choice callback", %{state: state} do
    parent = self()

    assert :continue =
             TuiModelEvent.handle(%{key: :enter}, state, callbacks(parent), draw(parent), cont())

    assert_received :choose_model
  end

  test "ignored keys continue without drawing", %{state: state} do
    parent = self()

    assert :continue =
             TuiModelEvent.handle(
               %{key: :char, char: "x"},
               state,
               callbacks(parent),
               draw(parent),
               cont()
             )

    refute_received :draw
    refute_received :choose_model
  end

  defp callbacks(parent) do
    %{choose_model: fn -> send(parent, :choose_model) end}
  end

  defp draw(parent), do: fn -> send(parent, :draw) end
  defp cont, do: fn -> :continue end
end
