defmodule Ourocode.Terminal.TuiDriverSessionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiDriverSession, TuiState}

  setup do
    state = TuiState.start_link()

    on_exit(fn ->
      if Process.alive?(state), do: Agent.stop(state)
    end)

    {:ok, state: state}
  end

  test "next_chunk drains buffered input before polling the helper", %{state: state} do
    TuiState.put_inbuf(state, "abc")

    assert TuiDriverSession.next_chunk(state, 0) == {:ok, "abc"}
    assert TuiDriverSession.next_chunk(state, 0) == :tick
  end

  test "next_chunk stores async file cache notifications and returns a repaint tick", %{
    state: state
  } do
    send(self(), {:file_cache_ready, ["lib/a.ex", "test/a_test.exs"]})

    assert TuiDriverSession.next_chunk(state, 0) == :tick
    assert TuiState.file_cache(state) == ["lib/a.ex", "test/a_test.exs"]
  end

  test "terminal control sequences enable SGR mouse reporting for ledger inspection" do
    assert TuiDriverSession.enter_sequence() =~ "?1003h"
    assert TuiDriverSession.enter_sequence() =~ "?1006h"
    assert TuiDriverSession.exit_sequence() =~ "?1003l"
    assert TuiDriverSession.exit_sequence() =~ "?1006l"
  end
end
