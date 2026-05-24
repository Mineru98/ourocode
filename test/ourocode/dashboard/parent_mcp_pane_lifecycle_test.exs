defmodule Ourocode.Dashboard.ParentMcpPaneLifecycleTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ParentMcpPaneLifecycle

  test "applies non-terminal parent call events to working panes" do
    state =
      ParentMcpPaneLifecycle.apply_event(new_state(), %{
        type: :parent_call_started,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        transport: :sse,
        external_ids: %{"session_id" => "session-1"},
        request_id: "call-1",
        method: "tools/call",
        params: %{"name" => "ooo.run"},
        event_seq: 1,
        occurred_at_ms: 10
      })

    assert [%{id: "parent-mcp:parent-1", status: :starting}] = state.working
    assert state.completed == []
    assert state.focused == "parent-mcp:parent-1"
    assert state.open == ["parent-mcp:parent-1"]
  end

  test "moves terminal parent call events to completed panes and merges counts" do
    started =
      ParentMcpPaneLifecycle.apply_event(new_state(), %{
        type: :parent_call_started,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        transport: :stdio,
        event_seq: 1,
        occurred_at_ms: 10
      })

    completed =
      ParentMcpPaneLifecycle.apply_event(started, %{
        type: :parent_call_result,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        transport: :stdio,
        result: %{"ok" => true},
        event_seq: 2,
        occurred_at_ms: 20
      })

    assert completed.working == []

    assert [
             %{
               id: "parent-mcp:parent-1",
               status: :completed,
               pane_state: %{event_count: 2}
             }
           ] = completed.completed
  end

  test "cleanup events remove matching parent panes and clear focus" do
    state =
      new_state()
      |> Map.put(:working, [
        %{
          id: "parent-mcp:parent-1",
          kind: :parent_mcp_call,
          parent_call_id: "parent-1"
        }
      ])
      |> Map.put(:focused, "parent-mcp:parent-1")
      |> Map.put(:open, ["parent-mcp:parent-1"])

    cleaned =
      ParentMcpPaneLifecycle.apply_event(state, %{
        cleanup_reason: :idle_timeout,
        stream_kind: :transport,
        parent_call_id: "parent-1"
      })

    assert cleaned.working == []
    assert cleaned.focused == nil
    assert cleaned.open == []
  end

  defp new_state do
    %{working: [], completed: [], focused: nil, open: []}
  end
end
