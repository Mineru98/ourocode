defmodule Ourocode.Terminal.TuiNormalNavigationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiNormalNavigation, TuiState}

  setup do
    state = TuiState.start_link()
    Agent.update(state, &%{&1 | buffer: "", cursor: 0, mode: :normal, pidx: 0})

    on_exit(fn ->
      try do
        if Process.alive?(state), do: Agent.stop(state)
      catch
        :exit, _reason -> :ok
      end
    end)

    %{state: state}
  end

  test "move_vertical changes history when no suggestion is active", %{state: state} do
    TuiState.remember_history(state, "first")

    assert :ok = TuiNormalNavigation.move_vertical(state, -1, true)
    assert TuiState.buffer(state) == "first"
    assert TuiState.pidx(state) == 0
  end

  test "move_vertical changes workspace selection before history when workspace is active", %{
    state: state
  } do
    TuiState.remember_history(state, "first")
    TuiState.put_workspace(state, workspace())

    assert :ok = TuiNormalNavigation.move_vertical(state, 1, true)
    assert get_in(TuiState.workspace(state), [:detail, :title]) == "Second"
    assert TuiState.buffer(state) == ""
  end

  test "move_vertical changes palette index while file mention suggestions are active", %{
    state: state
  } do
    Agent.update(state, &%{&1 | buffer: "@lib", cursor: 4, file_cache: ["lib/a.ex"]})

    assert :ok = TuiNormalNavigation.move_vertical(state, 1, true)
    assert TuiState.pidx(state) == 1
    assert TuiState.buffer(state) == "@lib"
  end

  test "move_vertical changes palette index while ooo suggestions are active", %{state: state} do
    Agent.update(state, &%{&1 | buffer: "ooo", cursor: 3})

    assert :ok = TuiNormalNavigation.move_vertical(state, -1, true)
    assert TuiState.pidx(state) == -1
  end

  defp workspace do
    first = %{id: "record:first", title: "First", actions: [%{command: "/first", enabled: true}]}

    second = %{
      id: "record:second",
      title: "Second",
      actions: [%{command: "/second", enabled: true}]
    }

    %{
      kind: "test",
      selected: "record:first",
      records: [first, second],
      detail: first,
      actions: []
    }
  end
end
