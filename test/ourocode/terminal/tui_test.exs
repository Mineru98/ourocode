defmodule Ourocode.Terminal.TuiTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Tui

  test "interactive? is false for captured StringIO devices" do
    {:ok, io} = StringIO.open("")

    refute Tui.interactive?(%{input: io, output: io})
  end

  test "interactive? is false when a custom read_line is supplied" do
    refute Tui.interactive?(%{input: :stdio, output: :stdio, read_line: fn _ -> :eof end})
  end

  test "interactive? is false while the ExUnit test runner is alive" do
    # This process always runs under ExUnit, so the runtime guard must keep
    # the raw-terminal driver from ever attaching during the test suite.
    refute Tui.interactive?(%{input: :stdio, output: :stdio})
  end

  test "native terminal control leaves mouse drag selection to the host terminal" do
    refute Tui.terminal_enter_sequence() =~ "?1000h"
    refute Tui.terminal_enter_sequence() =~ "?1006h"
    refute Tui.terminal_exit_sequence() =~ "?1000l"
    refute Tui.terminal_exit_sequence() =~ "?1006l"
  end

  test "edit_input inserts and deletes at the cursor" do
    assert {"abXc", 3} = Tui.edit_input("abc", 2, %{key: :char, char: "X"})
    assert {"ac", 1} = Tui.edit_input("abc", 2, %{key: :backspace})
    assert {"ab", 2} = Tui.edit_input("abc", 2, %{key: :delete})
  end

  test "edit_input supports readline-style cursor movement and kills" do
    assert {"abc", 0} = Tui.edit_input("abc", 3, %{key: :ctrl_a})
    assert {"abc", 3} = Tui.edit_input("abc", 0, %{key: :ctrl_e})
    assert {"world", 0} = Tui.edit_input("hello world", 6, %{key: :ctrl_u})
    assert {"hello ", 6} = Tui.edit_input("hello world", 6, %{key: :ctrl_k})
    assert {"hello ", 6} = Tui.edit_input("hello world", 11, %{key: :ctrl_w})
  end

  test "edit_input supports meta word movement and command backspace" do
    assert {"hello world", 6} = Tui.edit_input("hello world", 11, %{key: :alt_b})
    assert {"hello world", 5} = Tui.edit_input("hello world", 0, %{key: :alt_f})
    assert {"hello world", 11} = Tui.edit_input("hello world", 6, %{key: :alt_f})
    assert {"hello ", 6} = Tui.edit_input("hello world", 6, %{key: :alt_d})
    assert {"", 0} = Tui.edit_input("hello world", 5, %{key: :cmd_backspace})
  end

  test "edit_input normalizes pasted image file URIs into attachment tokens" do
    assert {"see @image:/tmp/screenshot.png", 30} =
             Tui.edit_input("see ", 4, %{key: :paste, char: "file:///tmp/screenshot.png"})
  end

  test "active_file_mention_query follows the cursor, not the buffer tail" do
    buffer = "ask @lib about @test"

    assert Tui.active_file_mention_query(buffer, 8) == "lib"
    assert Tui.active_file_mention_query(buffer, String.length(buffer)) == "test"
    assert Tui.active_file_mention_query(buffer, 3) == nil
  end
end
