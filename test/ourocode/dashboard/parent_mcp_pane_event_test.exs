defmodule Ourocode.Dashboard.ParentMcpPaneEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPaneEvent
  alias Ourocode.MCP.LifecycleEvent

  test "from_lifecycle_event builds a parent pane from normalized lifecycle data" do
    event =
      LifecycleEvent.new(:parent_call_event, %{
        event_seq: 7,
        transport: :sse,
        parent_call_id: "parent-7",
        runtime_source: "synthetic",
        external_ids: %{session_id: "session-7", childID: "child-7"},
        occurred_at_ms: 1234,
        request_id: "request-7",
        method: "tools/call",
        params: %{name: "ooo.run"},
        notification: %{"params" => %{"token" => "hello"}}
      })

    assert {:ok,
            %{
              id: "parent-mcp:parent-7",
              kind: :parent_mcp_call,
              status: :streaming,
              parent_call_id: "parent-7",
              runtime_source: "synthetic",
              transport: :sse,
              external_ids: %{session_id: "session-7", childID: "child-7"},
              request_id: "request-7",
              method: "tools/call",
              params: %{name: "ooo.run"},
              notification: %{"params" => %{"token" => "hello"}},
              stream_cursor: %{
                transport: :sse,
                parent_call_id: "parent-7",
                event_seq: 7
              },
              pane_state: %{
                open?: true,
                focused?: false,
                renderer: :default_parent_mcp,
                lifecycle_type: :parent_call_event,
                last_event_seq: 7,
                event_count: 1,
                notification_count: 1
              },
              created_at_ms: 1234,
              updated_at_ms: 1234
            }} = ParentMcpPaneEvent.from_lifecycle_event(event)
  end

  test "from_lifecycle_event ignores unrelated or incomplete events" do
    assert :ignore = ParentMcpPaneEvent.from_lifecycle_event(%{type: :child_session_started})

    assert :ignore =
             ParentMcpPaneEvent.from_lifecycle_event(%{
               type: :parent_call_started,
               parent_call_id: "parent-1",
               transport: :stdio
             })
  end

  test "terminal? detects terminal parent lifecycle events" do
    assert ParentMcpPaneEvent.terminal?(%{type: :parent_call_result})
    assert ParentMcpPaneEvent.terminal?(%{type: :transport_exited})
    refute ParentMcpPaneEvent.terminal?(%{type: :parent_call_event})
  end

  test "from_cleanup_event extracts parent call identifiers from cleanup events" do
    assert {:ok, %{parent_call_id: "parent-9"}} =
             ParentMcpPaneEvent.from_cleanup_event(%{
               cleanup_reason: :idle_timeout,
               stream_kind: :session,
               parentCallID: "parent-9"
             })

    assert {:ok, %{parent_call_id: "42"}} =
             ParentMcpPaneEvent.from_cleanup_event(%{
               lifecycle_type: :stream_terminated,
               cleanup_reason: :operation_timeout,
               stream_kind: :child,
               parent_call_id: 42
             })
  end

  test "from_cleanup_event ignores cleanup events without parent identity" do
    assert :ignore =
             ParentMcpPaneEvent.from_cleanup_event(%{
               cleanup_reason: :idle_timeout,
               stream_kind: :child
             })

    assert :ignore =
             ParentMcpPaneEvent.from_cleanup_event(%{
               cleanup_reason: :normal,
               stream_kind: :child,
               parent_call_id: "parent-1"
             })
  end
end
