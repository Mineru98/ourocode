defmodule Ourocode.Terminal.TuiPaletteTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.TuiPalette
  alias Ourocode.Terminal.TuiState

  setup do
    dir =
      Path.join(System.tmp_dir!(), "ourocode-tui-palette-#{System.unique_integer([:positive])}")

    previous = System.get_env("OUROCODE_STATE_DIR")
    System.put_env("OUROCODE_STATE_DIR", dir)

    state = TuiState.start_link()

    on_exit(fn ->
      if previous,
        do: System.put_env("OUROCODE_STATE_DIR", previous),
        else: System.delete_env("OUROCODE_STATE_DIR")

      File.rm_rf!(dir)
    end)

    %{state: state}
  end

  test "choice returns the selected slash command", %{state: state} do
    TuiState.put_mode(state, :palette)
    TuiState.edit_buffer(state, %{key: :char, char: "/"})
    TuiState.put_pidx(state, 0)

    assert TuiPalette.choice(state) =~ "/"
  end

  test "close returns to normal mode and clears buffer", %{state: state} do
    TuiState.put_mode(state, :palette)
    TuiState.edit_buffer(state, %{key: :paste, char: "/help"})

    assert :ok = TuiPalette.close(state)
    assert TuiState.mode(state) == :normal
    assert TuiState.buffer(state) == ""
    assert TuiState.pidx(state) == 0
  end

  test "handle_event moves palette selection and redraws", %{state: state} do
    TuiState.put_mode(state, :palette)
    TuiState.put_pidx(state, 0)
    parent = self()

    result =
      TuiPalette.handle_event(
        %{key: :down},
        state,
        fn _line -> :continue end,
        fn -> send(parent, :drawn) end,
        fn -> :continued end
      )

    assert result == :continued
    assert_receive :drawn
    assert TuiState.pidx(state) == 1
  end

  test "handle_event submits selected choice on enter", %{state: state} do
    TuiState.put_mode(state, :palette)
    TuiState.edit_buffer(state, %{key: :paste, char: "/help"})

    assert {:submit, "/help"} =
             TuiPalette.handle_event(
               %{key: :enter},
               state,
               fn line -> {:submit, line} end,
               fn -> :drawn end,
               fn -> :continued end
             )

    assert TuiState.mode(state) == :normal
  end
end
