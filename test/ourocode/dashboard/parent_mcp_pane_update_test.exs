defmodule Ourocode.Dashboard.ParentMcpPaneUpdateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPaneUpdate

  test "applies normalized updates while preserving immutable pane identity" do
    pane = %{
      id: "parent-mcp:parent-1",
      kind: :parent_mcp_call,
      status: :starting,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :stdio,
      external_ids: %{session_id: "session-1"},
      stream_cursor: %{event_seq: 1, transport: :stdio, parent_call_id: "parent-1"},
      pane_state: %{title: "Original"},
      created_at_ms: 100,
      updated_at_ms: 100
    }

    updated =
      ParentMcpPaneUpdate.apply(pane, %{
        "id" => "parent-mcp:wrong",
        "parent_call_id" => "wrong",
        "status" => "streaming",
        "runtime_source" => :opencode,
        "transport" => "sse",
        "external_ids" => %{childID: "child-1"},
        "stream_cursor" => %{event_seq: 2, parent_call_id: "wrong"},
        "pane_state" => %{title: "Updated", last_event_seq: 2},
        "params" => %{name: "ooo.run"},
        "updated_at_ms" => "200"
      })

    assert updated.id == "parent-mcp:parent-1"
    assert updated.parent_call_id == "parent-1"
    assert updated.status == :streaming
    assert updated.runtime_source == "opencode"
    assert updated.transport == :sse
    assert updated.external_ids == %{session_id: "session-1", childID: "child-1"}
    assert updated.stream_cursor == %{event_seq: 2, transport: :sse, parent_call_id: "parent-1"}
    assert updated.pane_state == %{title: "Updated", last_event_seq: 2}
    assert updated.params == %{name: "ooo.run"}
    assert updated.created_at_ms == 100
    assert updated.updated_at_ms == 200
  end

  test "ignores invalid scalar updates and keeps explicit nil values for payload fields" do
    pane = %{
      id: "parent-mcp:parent-1",
      kind: :parent_mcp_call,
      status: :starting,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :stdio,
      external_ids: %{},
      stream_cursor: %{transport: :stdio, parent_call_id: "parent-1"},
      pane_state: %{},
      result: %{old: true},
      created_at_ms: 100,
      updated_at_ms: 100
    }

    updated =
      ParentMcpPaneUpdate.apply(pane, %{
        status: "paused",
        transport: "websocket",
        updated_at_ms: "later",
        result: nil
      })

    assert updated.status == :starting
    assert updated.transport == :stdio
    assert updated.updated_at_ms == 100
    assert updated.result == nil
  end
end
