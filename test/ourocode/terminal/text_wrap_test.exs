defmodule Ourocode.Terminal.TextWrapTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Screen
  alias Ourocode.Terminal.TextWrap

  test "keeps text on one line when it fits" do
    assert TextWrap.wrap("hello there", 40) == ["hello there"]
  end

  test "wraps by display width without losing words" do
    assert TextWrap.wrap("one two three four", 9) == ["one two", "three", "four"]
  end

  test "hard-splits a single long token" do
    segments = TextWrap.wrap("abcdefghijkl", 5)

    assert Enum.join(segments) == "abcdefghijkl"
    assert Enum.all?(segments, &(Screen.text_width(&1) <= 5))
  end

  test "handles too-narrow widths and blank input" do
    assert TextWrap.wrap("世界中", 1) == ["世", "界", "中"]
    assert TextWrap.wrap("", 10) == [""]
    assert TextWrap.wrap("   ", 10) == [""]
    assert TextWrap.wrap(nil, 10) == [""]
  end
end
