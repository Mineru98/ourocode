defmodule Ourocode.Terminal.LayoutSegmentTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.LayoutSegment

  test "formats rect-backed terminal layout segments" do
    assert LayoutSegment.format(
             %{layout: %{region: :task_prompt, rect: %{x: 0, y: 20, width: 80, height: 3}}},
             "unknown"
           ) == "region=task_prompt x=0 y=20 w=80 h=3"
  end

  test "falls back to supplied region when layout is missing" do
    assert LayoutSegment.format(%{}, "queued_notifications") == "region=queued_notifications"
  end

  test "formats raw terminal rectangles" do
    assert LayoutSegment.rect(%{x: 0, y: 9, width: 80, height: 12}) == "x=0 y=9 w=80 h=12"
  end
end
