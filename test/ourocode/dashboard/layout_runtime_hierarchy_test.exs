defmodule Ourocode.Dashboard.LayoutRuntimeHierarchyTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.LayoutRuntimeHierarchy

  test "build nests children under matching parent calls and keeps orphans separate" do
    parent_state = %{
      working: [parent_pane("parent-1")],
      completed: [],
      focused: nil,
      open: []
    }

    child_state = %{
      working: [
        child_pane("child-1", "parent-1"),
        child_pane("child-orphan", "parent-orphan")
      ],
      completed: []
    }

    hierarchy = LayoutRuntimeHierarchy.build(parent_state, child_state)

    assert [%{parent_call_id: "parent-1", children: [%{child_id: "child-1"}]}] = hierarchy.roots
    assert [%{child_id: "child-orphan"}] = hierarchy.orphan_children
  end

  test "render_frame includes parent, child stream summaries, and orphan section" do
    hierarchy = %{
      id: :mcp_runtime_hierarchy,
      roots: [
        %{
          kind: :parent_mcp_call,
          status: "streaming",
          parent_call_id: "parent-1",
          runtime_source: "synthetic",
          transport: "sse",
          request_id: nil,
          method: nil,
          child_id: nil,
          stream_cursor: %{event_seq: 1},
          event_count: 1,
          notification_count: 0,
          line: "[streaming] parent=parent-1",
          children: [
            %{
              kind: :child_session,
              line: "[working] child=child-1",
              title: "Child One",
              stream_entries: [%{runtime_seq: 1, token: "hello"}]
            }
          ]
        }
      ],
      orphan_children: [
        %{
          kind: :child_session,
          line: "[working] child=child-orphan",
          title: "",
          stream_entries: []
        }
      ]
    }

    frame = LayoutRuntimeHierarchy.render_frame(hierarchy)

    assert frame =~ "MCP Runtime"
    assert frame =~ "[streaming] parent=parent-1"
    assert frame =~ "  [working] child=child-1 title=\"Child One\" stream=[1:token=hello]"
    assert frame =~ "Orphan Child Sessions"
    assert frame =~ "  [working] child=child-orphan"
  end

  defp parent_pane(parent_call_id) do
    %{
      id: "parent-mcp:" <> parent_call_id,
      kind: :parent_mcp_call,
      status: :streaming,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      transport: :sse,
      external_ids: %{},
      stream_cursor: %{event_seq: 1, transport: :sse, parent_call_id: parent_call_id},
      pane_state: %{lifecycle_type: :parent_call_event, event_count: 1, notification_count: 0},
      created_at_ms: 1,
      updated_at_ms: 1
    }
  end

  defp child_pane(child_id, parent_call_id) do
    %{
      id: "child-session:" <> child_id,
      kind: :child_session,
      status: :working,
      child_id: child_id,
      parent_call_id: parent_call_id,
      runtime_source: "synthetic",
      transport: :sse,
      external_ids: %{"childID" => child_id},
      stream_cursor: %{event_seq: 1, transport: :sse, child_id: child_id},
      pane_state: %{stream_entries: [%{runtime_seq: 1, token: "hello"}]},
      created_at_ms: 1,
      updated_at_ms: 1
    }
  end
end
