defmodule Ourocode.MCP.SessionGraphTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneEventRouter
  alias Ourocode.MCP.SessionGraph

  test "links multiple child sessions to the same parent MCP call" do
    events = [
      child_event("child-a", 1, "A started"),
      child_event("child-b", 2, "B started")
    ]

    topology_events = Enum.flat_map(events, &SessionGraph.topology_events/1)

    assert [
             %{
               type: :mcp_parent_child_linked,
               parent_call_id: "parent-1",
               child_id: "child-a"
             }
           ] =
             Enum.filter(
               topology_events,
               &(&1.type == :mcp_parent_child_linked and &1.child_id == "child-a")
             )

    assert [
             %{
               type: :mcp_parent_child_linked,
               parent_call_id: "parent-1",
               child_id: "child-b"
             }
           ] =
             Enum.filter(
               topology_events,
               &(&1.type == :mcp_parent_child_linked and &1.child_id == "child-b")
             )

    state =
      Enum.reduce(events, new_state(), fn event, state ->
        ChildSessionPaneEventRouter.apply_event(state, event)
      end)

    assert Enum.map(state.working, & &1.child_id) == ["child-a", "child-b"]
    assert state.open == ["child-session:child-a", "child-session:child-b"]

    assert state.child_pane_registry == %{
             "child-a" => "child-session:child-a",
             "child-b" => "child-session:child-b"
           }
  end

  test "emits only a parent topology event when no child session is present" do
    assert [
             %{
               type: :mcp_parent_call_seen,
               node_id: "mcp-parent:parent-1",
               parent_call_id: "parent-1",
               lifecycle_type: :parent_call_started
             }
           ] =
             SessionGraph.topology_events(%{
               type: :parent_call_started,
               parent_call_id: "parent-1",
               runtime_source: "ouroboros",
               transport: :streamable_http,
               event_seq: 0
             })
  end

  defp child_event(child_id, event_seq, token) do
    %{
      type: :parent_call_event,
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      event_seq: event_seq,
      occurred_at_ms: 100 + event_seq,
      notification: %{
        "method" => "session/update",
        "params" => %{"childID" => child_id, "token" => token}
      }
    }
  end

  defp new_state do
    %{working: [], completed: [], focused: nil, open: [], child_pane_registry: %{}}
  end
end
