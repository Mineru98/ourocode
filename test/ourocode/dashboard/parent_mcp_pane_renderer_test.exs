defmodule Ourocode.Dashboard.ParentMcpPaneRendererTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPaneRenderer

  test "renders parent MCP pane data and compact line" do
    pane = %{
      id: "parent-mcp:parent-render-1",
      kind: :parent_mcp_call,
      status: :streaming,
      parent_call_id: "parent-render-1",
      runtime_source: "opencode",
      transport: :sse,
      request_id: "call-render-1",
      method: "tools/call",
      external_ids: %{"childID" => "child-render-1"},
      stream_cursor: %{event_seq: 4, transport: :sse, parent_call_id: "parent-render-1"},
      pane_state: %{
        lifecycle_type: :parent_call_event,
        event_count: 3,
        notification_count: 2
      },
      updated_at_ms: 400
    }

    rendered = ParentMcpPaneRenderer.render(pane)

    assert rendered.status == "streaming"
    assert rendered.lifecycle == "parent_call_event"
    assert rendered.child_id == "child-render-1"

    assert rendered.line ==
             "[streaming] parent=parent-render-1 lifecycle=parent_call_event runtime=opencode transport=sse request=call-render-1 method=tools/call child=child-render-1 seq=4 events=3 notifications=2"

    assert ParentMcpPaneRenderer.line(pane) == rendered.line
    assert ParentMcpPaneRenderer.line(rendered) == rendered.line
  end
end
