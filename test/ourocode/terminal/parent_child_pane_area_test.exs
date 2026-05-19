defmodule Ourocode.Terminal.ParentChildPaneAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane}
  alias Ourocode.Terminal.ParentChildPaneArea

  test "renders distinct non-overlapping parent and child terminal pane regions" do
    parent_state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :stdio,
        parent_call_id: "parent-terminal-area-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-terminal-area-1"},
        occurred_at_ms: 100,
        request_id: "call-terminal-area-1",
        method: "tools/call",
        params: %{"name" => "ooo.run", "arguments" => %{"task" => "render parent child area"}}
      })

    {:ok, child_state} =
      ChildSessionPanes.register_child_pane(
        %{working: [], completed: [], focused: nil, open: []},
        %{
          child_id: "child-terminal-area-1",
          parent_call_id: "parent-terminal-area-1",
          runtime_source: "opencode",
          transport: :stdio,
          external_ids: %{"thread_id" => "thread-terminal-area-1"},
          stream_cursor: %{event_seq: 2},
          pane_state: %{
            title: "Terminal Child",
            last_event_seq: 2,
            stream_entries: [%{event_seq: 2, token: "visible"}]
          },
          created_at_ms: 2,
          updated_at_ms: 2
        }
      )

    area = ParentChildPaneArea.render(parent_state, child_state)
    frame = ParentChildPaneArea.render_text(area)

    assert area.kind == :parent_child_pane_area
    assert area.layout.mode == :terminal_split
    assert area.layout.regions.parent == %{x: 0, y: 0, width: 80, height: 8}
    assert area.layout.regions.child == %{x: 0, y: 9, width: 80, height: 12}

    assert area.layout.bounds == %{
             terminal_width: 80,
             terminal_height: 21,
             gap: 1,
             non_overlapping?: true,
             within_terminal?: true,
             positive_dimensions?: true
           }

    assert frame =~ "+-- Parent/Child Sessions region=runtime_panes layout=terminal_split"
    assert frame =~ "| [parent-region] x=0 y=0 w=80 h=8"
    assert frame =~ "| parent [starting] parent=parent-terminal-area-1"
    assert frame =~ "| [child-region] x=0 y=9 w=80 h=12"
    assert frame =~ "| child [working] child=child-terminal-area-1"
    assert frame =~ ~s(title="Terminal Child")
  end

  test "validates split pane bounds before rendering" do
    parent_region = %{x: 0, y: 0, width: 80, height: 8}
    child_region = %{x: 0, y: 9, width: 80, height: 12}

    assert ParentChildPaneArea.validate_bounds(parent_region, child_region) == %{
             terminal_width: 80,
             terminal_height: 21,
             gap: 1,
             non_overlapping?: true,
             within_terminal?: true,
             positive_dimensions?: true
           }

    overlapping_child = %{child_region | y: 7}
    offscreen_child = %{child_region | y: 10}

    refute ParentChildPaneArea.validate_bounds(parent_region, overlapping_child).non_overlapping?
    refute ParentChildPaneArea.validate_bounds(parent_region, offscreen_child).within_terminal?
  end
end
