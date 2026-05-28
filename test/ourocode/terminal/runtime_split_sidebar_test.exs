defmodule Ourocode.Terminal.RuntimeSplitSidebarTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RuntimeSplitSidebar, Screen}

  test "scroll_tail keeps the live tail and supports scrollback" do
    lines = Enum.map(1..6, &"line #{&1}")

    assert RuntimeSplitSidebar.scroll_tail(lines, 3, 0) == ["line 4", "line 5", "line 6"]
    assert RuntimeSplitSidebar.scroll_tail(lines, 3, 2) == ["line 2", "line 3", "line 4"]
    assert RuntimeSplitSidebar.scroll_tail(["only"], 3, 5) == ["only"]
  end

  test "section_heights reserves room for both parent and child sections" do
    parent = Enum.map(1..10, &"parent #{&1}")
    child = Enum.map(1..4, &"child #{&1}")

    {parent_h, child_h} = RuntimeSplitSidebar.section_heights(parent, child, 8)

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

    assert RuntimeSplitSidebar.pane_lines(body, "parent ") == ["parent-1 status=running"]
    assert RuntimeSplitSidebar.pane_lines(body, "child ") == ["child-1 event_seq=3"]
  end

  test "draw_section collapses idle sections and renders live and failed status" do
    idle =
      Screen.new(50, 8)
      |> RuntimeSplitSidebar.draw_section(1, 1, 30, "MCP parent", [], 2)
      |> Screen.to_lines()
      |> Enum.join("\n")

    live =
      Screen.new(50, 8)
      |> RuntimeSplitSidebar.draw_section(1, 1, 30, "MCP parent", ["session started"], 2)
      |> Screen.to_lines()
      |> Enum.join("\n")

    failed =
      Screen.new(50, 8)
      |> RuntimeSplitSidebar.draw_section(1, 1, 30, "MCP parent", ["session failed"], 2)
      |> Screen.to_lines()
      |> Enum.join("\n")

    refute idle =~ "MCP parent"
    assert live =~ "MCP parent ● live"
    assert failed =~ "MCP parent failed"
  end

  test "pane_lines turns compact task fields into product-facing rows" do
    body = [
      "parent task=PM interview state=waiting for answer elapsed=12s action=answer or cancel",
      "child agent=Answer choices state=choice ready current=What outcome should this produce?"
    ]

    assert RuntimeSplitSidebar.pane_lines(body, "parent ") == [
             "● Task PM interview",
             "  State waiting for answer · 12s",
             "  Action answer or cancel"
           ]

    assert RuntimeSplitSidebar.pane_lines(body, "child ") == [
             "● Agent Answer choices",
             "  State choice ready",
             "  Now What outcome should this produce?"
           ]
  end
end
