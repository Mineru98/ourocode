defmodule Ourocode.Terminal.TuiStateInitialTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.{PromptStore, TuiStateInitial}

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-tui-state-initial-#{System.unique_integer([:positive])}"
      )

    previous = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", dir)

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_STATE_DIR", previous),
        else: System.delete_env("OUROCODE_STATE_DIR")

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  test "build loads persisted draft and history", %{dir: dir} do
    PromptStore.save_draft("ooo interview", state_dir: dir)
    PromptStore.append_history("ooo seed", state_dir: dir)

    state = TuiStateInitial.build()

    assert state.buffer == "ooo interview"
    assert state.cursor == String.length("ooo interview")
    assert state.history == ["ooo seed"]
  end

  test "build sets transient TUI defaults" do
    state = TuiStateInitial.build()

    assert state.mode == :normal
    assert state.pidx == 0
    assert state.size == {120, 40}
    assert state.scroll == 0
    assert state.tick == 0
    assert state.wonder_nav == nil
    assert state.notifications == []
    assert state.prev_screen == nil
    assert state.render_theme == nil
    assert state.streaming == false
  end
end
