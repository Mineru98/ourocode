defmodule Ourocode.Terminal.ScreenTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Screen

  test "put_text writes a string at coordinates and clips to width" do
    lines =
      Screen.new(10, 3)
      |> Screen.put_text(2, 1, "hello world")
      |> Screen.to_lines()

    assert lines == ["", "  hello wo", ""]
  end

  test "put_text ignores out-of-bounds rows" do
    screen = Screen.new(5, 2)
    assert Screen.to_lines(Screen.put_text(screen, 0, 5, "x")) == ["", ""]
    assert Screen.to_lines(Screen.put_text(screen, 0, -1, "x")) == ["", ""]
  end

  test "box draws a rounded border with an inline title" do
    lines =
      Screen.new(20, 4)
      |> Screen.box(0, 0, 20, 4, "Status")
      |> Screen.to_lines()

    assert Enum.at(lines, 0) == "+- Status ---------+"
    assert Enum.at(lines, 1) == "|" <> String.duplicate(" ", 18) <> "|"
    assert Enum.at(lines, 3) == "+------------------+"
  end

  test "box without a title draws a plain top border" do
    [top | _] =
      Screen.new(6, 3)
      |> Screen.box(0, 0, 6, 3)
      |> Screen.to_lines()

    assert top == "+----+"
  end

  test "to_ansi emits a cursor-home positioned full frame" do
    ansi =
      Screen.new(4, 2)
      |> Screen.put_text(0, 0, "hi")
      |> Screen.to_ansi()
      |> IO.iodata_to_binary()

    assert String.starts_with?(ansi, "\e[2J\e[H")
    assert ansi =~ "\e[1;1H"
    assert ansi =~ "\e[2;1H"
    assert ansi =~ "hi"
  end

  test "diff against nil emits the full frame" do
    screen = Screen.put_text(Screen.new(4, 2), 0, 0, "ab")
    {iodata, returned} = Screen.diff(nil, screen)

    assert returned == screen
    assert IO.iodata_to_binary(iodata) =~ "ab"
  end

  test "diff emits only changed rows and is empty for an identical frame" do
    base =
      Screen.new(6, 3)
      |> Screen.put_text(0, 0, "row0")
      |> Screen.put_text(0, 2, "row2")

    {empty, ^base} = Screen.diff(base, base)
    assert IO.iodata_to_binary(empty) |> String.replace("\e[0m", "") == ""

    changed = Screen.put_text(base, 0, 2, "ROW2")
    {iodata, ^changed} = Screen.diff(base, changed)
    text = IO.iodata_to_binary(iodata)

    assert text =~ "\e[3;1H"
    assert text =~ "ROW2"
    refute text =~ "\e[1;1H"
  end

  test "styled text is wrapped in SGR codes and reset" do
    ansi =
      Screen.new(8, 1)
      |> Screen.put_text(0, 0, "ok", :ok)
      |> Screen.to_ansi()
      |> IO.iodata_to_binary()

    assert ansi =~ "\e[0;38;2;63;185;80m"
    assert ansi =~ "ok"
    assert String.ends_with?(ansi, "\e[0m")
  end

  test "char_width/text_width treat CJK/Hangul as two columns" do
    assert Screen.char_width("a") == 1
    assert Screen.char_width("한") == 2
    assert Screen.char_width("中") == 2
    assert Screen.text_width("hi한글") == 2 + 2 + 2
  end

  test "truncate clips by display width, not grapheme count" do
    assert Screen.truncate("한글ab", 5) == "한글a"
    assert Screen.truncate("한글ab", 4) == "한글"
    assert Screen.truncate("한글ab", 3) == "한"
    assert Screen.truncate("abc", 0) == ""
  end

  test "wide glyphs occupy two cells and do not desync following columns" do
    lines =
      Screen.new(12, 1)
      |> Screen.put_text(0, 0, "한glx")
      |> Screen.to_lines()

    # '한'(2) + 'g'(1) 'l'(1) 'x'(1) = 5 display columns, no shifting.
    assert hd(lines) == "한glx"

    ansi =
      Screen.new(12, 1)
      |> Screen.put_text(0, 0, "한x")
      |> Screen.to_ansi()
      |> IO.iodata_to_binary()

    # The continuation cell emits nothing, so 'x' is not pushed right.
    assert ansi =~ "한x"
  end
end
