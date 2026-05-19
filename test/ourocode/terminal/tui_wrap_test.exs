defmodule Ourocode.Terminal.TuiWrapTest do
  @moduledoc """
  The interview block word-wraps to the left column instead of hard-clipping,
  so long (often CJK) questions/options stay fully readable and never bleed
  into the right pane. `wrap_text/2` is the width-aware core.
  """

  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Screen
  alias Ourocode.Terminal.Tui

  test "short text stays a single unchanged segment" do
    assert Tui.wrap_text("hello there", 40) == ["hello there"]
  end

  test "spaced text wraps so no segment exceeds the width" do
    text = "the quick brown fox jumps over the lazy dog again and again"
    segments = Tui.wrap_text(text, 20)

    assert length(segments) > 1
    assert Enum.all?(segments, &(Screen.text_width(&1) <= 20))
    # No word is lost or split across the wrap (rejoined == original words).
    assert segments |> Enum.join(" ") |> String.split() == String.split(text)
  end

  test "a single token longer than the width is hard-split, losing nothing" do
    token = String.duplicate("a", 50)
    segments = Tui.wrap_text(token, 12)

    assert Enum.all?(segments, &(Screen.text_width(&1) <= 12))
    assert Enum.join(segments) == token
  end

  test "wrapping is display-width aware for CJK (2 columns per glyph)" do
    # 6 Hangul syllables = 12 display columns; width 8 must break them up.
    text = "가나다라마바"
    segments = Tui.wrap_text(text, 8)

    assert length(segments) >= 2
    assert Enum.all?(segments, &(Screen.text_width(&1) <= 8))
    assert Enum.join(segments) == text
  end

  test "a width too small for a double-width glyph still terminates" do
    # Regression: truncate/2 returns "" here; hard_split must force progress.
    segments = Tui.wrap_text("가나다", 1)
    assert Enum.join(segments) == "가나다"
    assert length(segments) == 3
  end

  test "blank input yields a single empty segment" do
    assert Tui.wrap_text("", 10) == [""]
    assert Tui.wrap_text("   ", 10) == [""]
  end
end
