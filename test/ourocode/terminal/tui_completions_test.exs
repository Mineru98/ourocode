defmodule Ourocode.Terminal.TuiCompletionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{TuiCompletions, TuiState}

  test "active_file_mention_query delegates cursor-aware mention parsing" do
    assert TuiCompletions.active_file_mention_query("open @lib/ouro", 14) == "lib/ouro"
    assert TuiCompletions.active_file_mention_query("open lib/ouro", 13) == nil
  end

  test "file_mention_suggestions ranks cached files for the active query" do
    state = TuiState.start_link()

    Agent.update(state, fn tui_state ->
      %{tui_state | buffer: "open @term", cursor: String.length("open @term")}
    end)

    TuiState.put_file_cache(state, [
      "lib/ourocode/terminal/tui.ex",
      "lib/ourocode/runtime/loop_bindings.ex"
    ])

    assert [{"lib/ourocode/terminal/tui.ex", _label}] =
             TuiCompletions.file_mention_suggestions(state, :normal, false)
  end

  test "insert_file_mention_choice replaces the active mention with the selected path" do
    state = TuiState.start_link()

    Agent.update(state, fn tui_state ->
      %{tui_state | buffer: "open @term", cursor: String.length("open @term")}
    end)

    TuiState.put_file_cache(state, ["lib/ourocode/terminal/tui.ex"])

    assert :ok = TuiCompletions.insert_file_mention_choice(state)

    assert Agent.get(state, & &1.buffer) == "open @lib/ourocode/terminal/tui.ex "
    assert Agent.get(state, & &1.cursor) == String.length("open @lib/ourocode/terminal/tui.ex ")
  end

  test "insert_active_choice completes the selected ooo command" do
    state = TuiState.start_link()

    Agent.update(state, fn tui_state ->
      %{tui_state | buffer: "ooo int", cursor: String.length("ooo int"), pidx: 0}
    end)

    assert TuiCompletions.insert_active_choice(state, true)
    assert Agent.get(state, & &1.buffer) == "ooo interview "
    assert Agent.get(state, & &1.cursor) == String.length("ooo interview ")
    assert Agent.get(state, & &1.pidx) == 0
  end

  test "insert_active_choice leaves normal input unchanged" do
    state = TuiState.start_link()

    Agent.update(state, fn tui_state ->
      %{tui_state | buffer: "normal input", cursor: String.length("normal input"), pidx: 0}
    end)

    refute TuiCompletions.insert_active_choice(state, true)
    assert Agent.get(state, & &1.buffer) == "normal input"
  end
end
