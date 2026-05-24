defmodule Ourocode.Terminal.InputEditOperationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InputEditOperation

  test "apply inserts characters and normalized paste" do
    assert InputEditOperation.apply(String.graphemes("abc"), 2, %{key: :char, char: "X"}) ==
             {String.graphemes("abXc"), 3}

    assert InputEditOperation.apply(String.graphemes("see "), 4, %{
             key: :paste,
             char: "file:///tmp/screenshot.png"
           }) ==
             {String.graphemes("see @image:/tmp/screenshot.png"), 30}
  end

  test "apply deletes around the cursor" do
    assert InputEditOperation.apply(String.graphemes("abc"), 2, %{key: :backspace}) ==
             {String.graphemes("ac"), 1}

    assert InputEditOperation.apply(String.graphemes("abc"), 2, %{key: :delete}) ==
             {String.graphemes("ab"), 2}

    assert InputEditOperation.apply(String.graphemes("abc"), 2, %{key: :ctrl_d}) ==
             {String.graphemes("ab"), 2}
  end

  test "apply moves cursor without changing text" do
    graphemes = String.graphemes("abc")

    assert InputEditOperation.apply(graphemes, 1, %{key: :left}) == {graphemes, 0}
    assert InputEditOperation.apply(graphemes, 1, %{key: :right}) == {graphemes, 2}
    assert InputEditOperation.apply(graphemes, 1, %{key: :ctrl_a}) == {graphemes, 0}
    assert InputEditOperation.apply(graphemes, 1, %{key: :ctrl_e}) == {graphemes, 3}
  end

  test "apply handles kill and word commands" do
    graphemes = String.graphemes("hello world")

    assert InputEditOperation.apply(graphemes, 6, %{key: :ctrl_u}) ==
             {String.graphemes("world"), 0}

    assert InputEditOperation.apply(graphemes, 6, %{key: :ctrl_k}) ==
             {String.graphemes("hello "), 6}

    assert InputEditOperation.apply(graphemes, 11, %{key: :ctrl_w}) ==
             {String.graphemes("hello "), 6}

    assert InputEditOperation.apply(graphemes, 6, %{key: :alt_d}) ==
             {String.graphemes("hello "), 6}
  end

  test "apply ignores yank keys and unknown events" do
    graphemes = String.graphemes("abc")

    assert InputEditOperation.apply(graphemes, 1, %{key: :ctrl_y}) == {graphemes, 1}
    assert InputEditOperation.apply(graphemes, 1, %{key: :alt_y}) == {graphemes, 1}
    assert InputEditOperation.apply(graphemes, 1, %{key: :unknown}) == {graphemes, 1}
  end
end
