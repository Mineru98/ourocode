defmodule Ourocode.Terminal.OverlayWindowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.OverlayWindow

  test "visible returns an empty window for empty items" do
    assert OverlayWindow.visible([], 10, 8) == {0, []}
  end

  test "visible keeps short lists at offset zero" do
    assert OverlayWindow.visible([:a, :b, :c], 2, 8) == {0, [a: 0, b: 1, c: 2]}
  end

  test "visible clamps negative selection to the first window" do
    assert OverlayWindow.visible(Enum.to_list(1..10), -5, 4) ==
             {0, [{1, 0}, {2, 1}, {3, 2}, {4, 3}]}
  end

  test "visible slides forward when the selected row passes the window" do
    assert OverlayWindow.visible(Enum.to_list(1..10), 7, 4) ==
             {4, [{5, 4}, {6, 5}, {7, 6}, {8, 7}]}
  end

  test "visible clamps selection beyond the final row" do
    assert OverlayWindow.visible(Enum.to_list(1..10), 99, 4) ==
             {6, [{7, 6}, {8, 7}, {9, 8}, {10, 9}]}
  end
end
