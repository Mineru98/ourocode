defmodule Ourocode.Terminal.RuntimeSplitTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RuntimeSplit

  test "scroll_tail keeps the live tail and supports scrollback" do
    lines = Enum.map(1..6, &"line #{&1}")

    assert RuntimeSplit.scroll_tail(lines, 3, 0) == ["line 4", "line 5", "line 6"]
    assert RuntimeSplit.scroll_tail(lines, 3, 2) == ["line 2", "line 3", "line 4"]
    assert RuntimeSplit.scroll_tail(["only"], 3, 5) == ["only"]
  end

  test "section_heights reserves room for both parent and child sections" do
    parent = Enum.map(1..10, &"parent #{&1}")
    child = Enum.map(1..4, &"child #{&1}")

    {parent_h, child_h} = RuntimeSplit.section_heights(parent, child, 8)

    assert parent_h >= 1
    assert child_h >= 1
    assert parent_h + child_h + 4 <= 8
  end

  test "pane_lines filters empty panes and humanizes compact runtime fields" do
    body = [
      "parent empty",
      "parent id=parent-1 status=running",
      "child empty",
      "child id=child-1 event_seq=3"
    ]

    assert RuntimeSplit.pane_lines(body, "parent ") == ["parent-1 status=running"]
    assert RuntimeSplit.pane_lines(body, "child ") == ["child-1 event_seq=3"]
  end
end
