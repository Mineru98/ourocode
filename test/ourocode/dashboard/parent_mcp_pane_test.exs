defmodule Ourocode.Dashboard.ParentMcpPaneTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPane
  alias Ourocode.MCP.LifecycleEvent

  test "parent pane model creation stores first-class panes retrievable by generated id" do
    assert {:ok, state} =
             ParentMcpPane.register_parent_pane(ParentMcpPane.new(), %{
               parent_call_id: "parent-create-1",
               runtime_source: "synthetic",
               transport: :stdio,
               external_ids: %{session_id: "session-create-1"},
               request_id: "call-create-1",
               method: "tools/call",
               stream_cursor: %{event_seq: 7},
               pane_state: %{title: "Created parent pane"},
               created_at_ms: 100,
               updated_at_ms: 120
             })

    pane_id = ParentMcpPane.parent_pane_id("parent-create-1")

    assert pane_id == "parent-mcp:parent-create-1"
    assert state.focused == pane_id
    assert state.open == [pane_id]

    assert {:ok,
            %{
              id: ^pane_id,
              kind: :parent_mcp_call,
              status: :starting,
              parent_call_id: "parent-create-1",
              runtime_source: "synthetic",
              transport: :stdio,
              external_ids: %{session_id: "session-create-1"},
              request_id: "call-create-1",
              method: "tools/call",
              stream_cursor: %{
                event_seq: 7,
                transport: :stdio,
                parent_call_id: "parent-create-1"
              },
              pane_state: %{
                open?: true,
                focused?: false,
                renderer: :default_parent_mcp,
                lifecycle_type: :parent_pane_registered,
                title: "Created parent pane"
              },
              created_at_ms: 100,
              updated_at_ms: 120
            }} = ParentMcpPane.fetch_pane(state, pane_id)
  end

  test "parent pane reads after updates preserve existing pane id" do
    assert {:ok, state} =
             ParentMcpPane.register_parent_pane(ParentMcpPane.new(), %{
               parent_call_id: "parent-update-1",
               runtime_source: "synthetic",
               transport: :sse,
               external_ids: %{session_id: "session-update-1"},
               stream_cursor: %{event_seq: 1},
               pane_state: %{title: "Original parent pane"},
               created_at_ms: 100,
               updated_at_ms: 100
             })

    pane_id = ParentMcpPane.parent_pane_id("parent-update-1")

    assert {:ok, state} =
             ParentMcpPane.update_parent_pane(state, pane_id, %{
               id: "parent-mcp:should-not-replace",
               pane_id: "parent-mcp:should-not-replace",
               parent_call_id: "parent-update-rewritten",
               runtime_source: "opencode",
               status: :streaming,
               external_ids: %{childID: "child-update-1"},
               stream_cursor: %{event_seq: 2, parent_call_id: "parent-update-rewritten"},
               pane_state: %{title: "Updated parent pane", last_event_seq: 2},
               updated_at_ms: 200
             })

    assert state.focused == pane_id
    assert state.open == [pane_id]
    assert [%{id: ^pane_id}] = state.working
    assert state.completed == []

    assert {:ok,
            %{
              id: ^pane_id,
              parent_call_id: "parent-update-1",
              runtime_source: "opencode",
              status: :streaming,
              external_ids: %{session_id: "session-update-1", childID: "child-update-1"},
              stream_cursor: %{
                event_seq: 2,
                transport: :sse,
                parent_call_id: "parent-update-1"
              },
              pane_state: %{
                title: "Updated parent pane",
                last_event_seq: 2
              },
              created_at_ms: 100,
              updated_at_ms: 200
            }} = ParentMcpPane.fetch_pane(state, pane_id)

    assert {:error, :parent_pane_not_found} =
             ParentMcpPane.fetch_pane(state, "parent-mcp:should-not-replace")
  end

  test "normalized parent MCP lifecycle events update live pane state" do
    initial_state = %{working: [], completed: [], focused: nil, open: []}

    started =
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 1,
        transport: :streamable_http,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{session_id: "session-1", call_id: "call-1"},
        occurred_at_ms: 100,
        request_id: "call-1",
        method: "tools/call",
        params: %{name: "ooo.run", arguments: %{task: "ping"}}
      })

    streaming =
      LifecycleEvent.new(:parent_call_event, %{
        event_seq: 2,
        transport: :streamable_http,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{session_id: "session-1", childID: "child-1"},
        occurred_at_ms: 200,
        notification: %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-1", "seq" => 1, "token" => "hello"}
        }
      })

    completed =
      LifecycleEvent.new(:parent_call_result, %{
        event_seq: 3,
        transport: :streamable_http,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{session_id: "session-1", childID: "child-1"},
        occurred_at_ms: 300,
        request_id: "call-1",
        result: %{"ok" => true, "seq" => 2}
      })

    state = ParentMcpPane.apply_event(initial_state, started)

    assert %{
             working: [
               %{
                 id: "parent-mcp:parent-1",
                 kind: :parent_mcp_call,
                 status: :starting,
                 parent_call_id: "parent-1",
                 runtime_source: "synthetic",
                 transport: :streamable_http,
                 external_ids: %{session_id: "session-1", call_id: "call-1"},
                 request_id: "call-1",
                 method: "tools/call",
                 stream_cursor: %{
                   transport: :streamable_http,
                   parent_call_id: "parent-1",
                   event_seq: 1
                 },
                 pane_state: %{
                   open?: true,
                   focused?: false,
                   renderer: :default_parent_mcp,
                   lifecycle_type: :parent_call_started,
                   last_event_seq: 1,
                   event_count: 1,
                   notification_count: 0
                 },
                 created_at_ms: 100,
                 updated_at_ms: 100
               }
             ],
             completed: [],
             focused: "parent-mcp:parent-1",
             open: ["parent-mcp:parent-1"]
           } = state

    state = ParentMcpPane.apply_event(state, streaming)

    assert [
             %{
               status: :streaming,
               external_ids: %{
                 session_id: "session-1",
                 call_id: "call-1",
                 childID: "child-1"
               },
               notification: %{
                 "params" => %{"childID" => "child-1", "seq" => 1, "token" => "hello"}
               },
               stream_cursor: %{event_seq: 2},
               pane_state: %{
                 lifecycle_type: :parent_call_event,
                 last_event_seq: 2,
                 event_count: 2,
                 notification_count: 1
               },
               created_at_ms: 100,
               updated_at_ms: 200
             }
           ] = state.working

    state = ParentMcpPane.apply_event(state, completed)

    assert state.working == []

    assert [
             %{
               id: "parent-mcp:parent-1",
               status: :completed,
               result: %{"ok" => true, "seq" => 2},
               stream_cursor: %{event_seq: 3},
               pane_state: %{
                 lifecycle_type: :parent_call_result,
                 last_event_seq: 3,
                 event_count: 3,
                 notification_count: 1
               },
               created_at_ms: 100,
               updated_at_ms: 300
             }
           ] = state.completed

    assert state.focused == "parent-mcp:parent-1"
    assert state.open == ["parent-mcp:parent-1"]
  end

  test "renders lifecycle state changes from the parent MCP pane model" do
    initial_state = %{working: [], completed: [], focused: nil, open: []}

    started =
      LifecycleEvent.new(:parent_call_started, %{
        event_seq: 1,
        transport: :sse,
        parent_call_id: "parent-ui-1",
        runtime_source: "opencode",
        external_ids: %{session_id: "session-ui-1", call_id: "call-ui-1"},
        occurred_at_ms: 100,
        request_id: "call-ui-1",
        method: "tools/call"
      })

    streaming =
      LifecycleEvent.new(:parent_call_event, %{
        event_seq: 2,
        transport: :sse,
        parent_call_id: "parent-ui-1",
        runtime_source: "opencode",
        external_ids: %{childID: "child-ui-1"},
        occurred_at_ms: 200,
        notification: %{"params" => %{"childID" => "child-ui-1", "seq" => 1, "token" => "hello"}}
      })

    completed =
      LifecycleEvent.new(:parent_call_result, %{
        event_seq: 3,
        transport: :sse,
        parent_call_id: "parent-ui-1",
        runtime_source: "opencode",
        external_ids: %{childID: "child-ui-1"},
        occurred_at_ms: 300,
        request_id: "call-ui-1",
        result: %{"ok" => true}
      })

    state = ParentMcpPane.apply_event(initial_state, started)
    rendered = ParentMcpPane.render(state)

    assert %{
             id: :parent_mcp_calls,
             title: "Parent MCP",
             empty?: false,
             focused: "parent-mcp:parent-ui-1",
             open: ["parent-mcp:parent-ui-1"],
             working: [
               %{
                 status: "starting",
                 lifecycle: "parent_call_started",
                 line:
                   "[starting] parent=parent-ui-1 lifecycle=parent_call_started runtime=opencode transport=sse request=call-ui-1 method=tools/call seq=1 events=1 notifications=0"
               }
             ],
             completed: []
           } = rendered

    state = ParentMcpPane.apply_event(state, streaming)
    rendered = ParentMcpPane.render(state)

    assert [
             %{
               status: "streaming",
               lifecycle: "parent_call_event",
               child_id: "child-ui-1",
               stream_cursor: %{event_seq: 2},
               event_count: 2,
               notification_count: 1
             } = streaming_pane
           ] = rendered.working

    assert ParentMcpPane.render_line(streaming_pane) ==
             "[streaming] parent=parent-ui-1 lifecycle=parent_call_event runtime=opencode transport=sse request=call-ui-1 method=tools/call child=child-ui-1 seq=2 events=2 notifications=1"

    state = ParentMcpPane.apply_event(state, completed)
    rendered = ParentMcpPane.render(state)

    assert rendered.working == []

    assert [
             %{
               status: "completed",
               lifecycle: "parent_call_result",
               child_id: "child-ui-1",
               line:
                 "[completed] parent=parent-ui-1 lifecycle=parent_call_result runtime=opencode transport=sse request=call-ui-1 method=tools/call child=child-ui-1 seq=3 events=3 notifications=1"
             }
           ] = rendered.completed
  end

  test "failed parent lifecycle events move the pane to completed with failed status" do
    state =
      %{working: [], completed: [], focused: nil, open: []}
      |> ParentMcpPane.apply_event(%{
        event_seq: 1,
        type: :parent_call_started,
        transport: :stdio,
        parent_call_id: "parent-2",
        runtime_source: "synthetic",
        external_ids: %{},
        occurred_at_ms: 100,
        request_id: "call-2"
      })
      |> ParentMcpPane.apply_event(%{
        event_seq: 2,
        type: :parent_call_failed,
        transport: :stdio,
        parent_call_id: "parent-2",
        runtime_source: "synthetic",
        external_ids: %{},
        occurred_at_ms: 200,
        request_id: "call-2",
        error: {:timeout, "call-2"}
      })

    assert state.working == []

    assert [
             %{
               id: "parent-mcp:parent-2",
               status: :failed,
               error: {:timeout, "call-2"},
               pane_state: %{event_count: 2, last_event_seq: 2}
             }
           ] = state.completed
  end
end
