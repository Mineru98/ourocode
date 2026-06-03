defmodule Ourocode.Dashboard.PaneOrchestratorTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.PaneOrchestrator

  test "creates a parent pane and multiple child panes from one MCP parent call" do
    state =
      [
        parent_started(),
        child_event("child-a", 2, "A started"),
        child_event("child-b", 3, "B started"),
        parent_completed()
      ]
      |> PaneOrchestrator.from_events()

    assert [%{parent_call_id: "parent-1", status: :completed}] = state.parents.completed
    assert Enum.map(state.children.working, & &1.child_id) == ["child-a", "child-b"]
    assert state.children.open == ["child-session:child-a", "child-session:child-b"]

    graph = PaneOrchestrator.graph(state)

    assert Enum.map(graph.edges, & &1.child_id) == ["child-a", "child-b"]

    assert %{
             id: "mcp-parent:parent-1",
             kind: :parent_call,
             parent_call_id: "parent-1",
             lifecycle_type: :parent_call_result,
             latest_event_seq: 4
           } = Enum.find(graph.nodes, &(&1.id == "mcp-parent:parent-1"))

    assert %{
             id: "child-session:child-a",
             kind: :child_session,
             parent_call_id: "parent-1",
             child_id: "child-a"
           } = Enum.find(graph.nodes, &(&1.id == "child-session:child-a"))
  end

  test "can continue from loop-binding parent child state keys" do
    state =
      %{parent: %{}, child: %{}}
      |> PaneOrchestrator.apply_event(parent_started())
      |> PaneOrchestrator.apply_event(child_event("child-a", 2, "A started"))

    assert [%{parent_call_id: "parent-1"}] = state.parents.working
    assert [%{child_id: "child-a"}] = state.children.working
  end

  test "moves child panes to completed when runtime emits an explicit completed result" do
    state =
      [
        parent_started(),
        child_event("child-a", 2, "A started"),
        child_completed("child-a", 3)
      ]
      |> PaneOrchestrator.from_events()

    assert state.children.working == []
    assert [%{child_id: "child-a", status: :completed}] = state.children.completed

    assert [%{child_id: "child-a", latest_event_seq: 3}] =
             PaneOrchestrator.graph(state).edges
  end

  defp parent_started do
    %{
      type: :parent_call_started,
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      event_seq: 1,
      occurred_at_ms: 101,
      method: "tools/call",
      params: %{"name" => "ouroboros_auto"}
    }
  end

  defp parent_completed do
    %{
      type: :parent_call_result,
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      event_seq: 4,
      occurred_at_ms: 104,
      result: %{"status" => "started"}
    }
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
        "params" => %{"childID" => child_id, "seq" => event_seq, "token" => token}
      }
    }
  end

  defp child_completed(child_id, event_seq) do
    %{
      type: :parent_call_result,
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      event_seq: event_seq,
      occurred_at_ms: 100 + event_seq,
      result: %{
        "childID" => child_id,
        "seq" => event_seq,
        "status" => "completed"
      }
    }
  end
end
