defmodule Ourocode.Terminal.TuiNormalKeyTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TuiNormalKey

  test "editing? accepts readline and deletion keys" do
    for key <- [:delete, :left, :right, :ctrl_a, :ctrl_k, :ctrl_y, :alt_f, :cmd_backspace] do
      assert TuiNormalKey.editing?(%{key: key})
    end
  end

  test "editing? rejects non-editing events" do
    refute TuiNormalKey.editing?(%{key: :enter})
    refute TuiNormalKey.editing?(%{key: :page_up})
    refute TuiNormalKey.editing?(%{type: :mouse, key: :wheel_up})
  end

  test "scroll_delta maps page and wheel events" do
    assert TuiNormalKey.scroll_delta(%{type: :mouse, key: :wheel_up}) == 3
    assert TuiNormalKey.scroll_delta(%{type: :mouse, key: :wheel_down}) == -3
    assert TuiNormalKey.scroll_delta(%{key: :page_up}) == 8
    assert TuiNormalKey.scroll_delta(%{key: :page_down}) == -8
  end

  test "scroll_delta ignores non-scroll events" do
    assert TuiNormalKey.scroll_delta(%{key: :char, char: "x"}) == nil
    assert TuiNormalKey.scroll_delta(%{key: :enter}) == nil
  end
end
