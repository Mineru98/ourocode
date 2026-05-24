defmodule Ourocode.Dashboard.ParentMcpPaneRegistrationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPane
  alias Ourocode.Dashboard.ParentMcpPaneRegistration

  test "registers a parent pane from metadata" do
    assert {:ok, state} =
             ParentMcpPaneRegistration.register(ParentMcpPane.new(), %{
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

    assert [
             %{
               id: "parent-mcp:parent-create-1",
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
                 event_count: 0,
                 notification_count: 0,
                 title: "Created parent pane"
               },
               created_at_ms: 100,
               updated_at_ms: 120
             }
           ] = state.working

    assert state.completed == []
    assert state.focused == "parent-mcp:parent-create-1"
    assert state.open == ["parent-mcp:parent-create-1"]
  end

  test "updates existing panes without replacing stable creation metadata" do
    {:ok, state} =
      ParentMcpPaneRegistration.register(ParentMcpPane.new(), %{
        parent_call_id: "parent-repeat-1",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{session_id: "session-1"},
        pane_state: %{title: "Initial"},
        created_at_ms: 100,
        updated_at_ms: 100
      })

    assert {:ok, state} =
             ParentMcpPaneRegistration.register(state, %{
               parent_call_id: "parent-repeat-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{childID: "child-1"},
               pane_state: %{title: "Updated", notification_count: 2},
               created_at_ms: 999,
               updated_at_ms: 200
             })

    assert [
             %{
               id: "parent-mcp:parent-repeat-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{session_id: "session-1", childID: "child-1"},
               pane_state: %{event_count: 1, notification_count: 2, title: "Updated"},
               created_at_ms: 100,
               updated_at_ms: 200
             }
           ] = state.working
  end

  test "moves completed panes back to working when directly registered again" do
    completed = %{
      id: "parent-mcp:parent-completed-1",
      kind: :parent_mcp_call,
      status: :completed,
      parent_call_id: "parent-completed-1",
      runtime_source: "synthetic",
      transport: :stdio,
      external_ids: %{},
      stream_cursor: %{},
      pane_state: %{event_count: 3, notification_count: 1},
      created_at_ms: 100,
      updated_at_ms: 150
    }

    state = %{ParentMcpPane.new() | completed: [completed]}

    assert {:ok, state} =
             ParentMcpPaneRegistration.register(state, %{
               parent_call_id: "parent-completed-1",
               runtime_source: "synthetic",
               transport: :stdio,
               updated_at_ms: 200
             })

    assert [%{id: "parent-mcp:parent-completed-1", status: :starting}] = state.working
    assert state.completed == []
  end

  test "rejects invalid state or metadata" do
    assert ParentMcpPaneRegistration.register(ParentMcpPane.new(), %{}) ==
             {:error, :invalid_parent_pane_metadata}

    assert ParentMcpPaneRegistration.register(%{working: []}, %{
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             transport: :stdio
           }) == {:error, :invalid_parent_pane_metadata}
  end
end
