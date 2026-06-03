defmodule Ourocode.ACP.ProjectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.PaneOrchestrator
  alias Ourocode.ACP.Projection

  test "projects tool calls, agent sessions, and graph edges from runtime events" do
    projection =
      Projection.new()
      |> Projection.apply_runtime_event(%{
        type: :parent_call_started,
        parent_call_id: "parent-proj-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        event_seq: 1
      })
      |> Projection.apply_runtime_event(%{
        type: :parent_call_event,
        parent_call_id: "parent-proj-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        event_seq: 2,
        notification: %{"params" => %{"childID" => "child-proj-1", "token" => "hi"}}
      })

    assert %{status: :streaming, latest_event_seq: 2} =
             projection.tool_calls["parent-proj-1"]

    assert %{parent_call_id: "parent-proj-1"} = projection.agent_sessions["child-proj-1"]

    assert %{
             "mcp-parent:parent-proj-1->child-session:child-proj-1" => %{
               kind: :parent_child
             }
           } = projection.graph.edges
  end

  test "projects workflow runs as ACP graph roots" do
    projection =
      Projection.apply_runtime_event(Projection.new(), %{
        type: :workflow_run_started,
        workflow_run_id: "workflow-run:parent-proj-2",
        parent_call_id: "parent-proj-2",
        runtime_source: "ourocode",
        transport: :local,
        route: :ouroboros_workflow,
        adapter_route: :run,
        status: :dispatching,
        event_seq: 1
      })

    assert %{status: :dispatching, route: :ouroboros_workflow} =
             projection.workflow_runs["workflow-run:parent-proj-2"]

    assert %{
             "workflow-run:parent-proj-2->mcp-parent:parent-proj-2" => %{
               kind: :run_parent_call
             }
           } = projection.graph.edges
  end

  test "uses MCP topology-compatible parent child graph ids" do
    events = [
      %{
        type: :parent_call_started,
        parent_call_id: "parent-parity-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        event_seq: 1
      },
      %{
        type: :parent_call_event,
        parent_call_id: "parent-parity-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        event_seq: 2,
        notification: %{"params" => %{"childID" => "child-parity-1", "token" => "hi"}}
      }
    ]

    acp =
      Enum.reduce(events, Projection.new(), fn event, projection ->
        Projection.apply_runtime_event(projection, event)
      end)

    pane_graph =
      events
      |> PaneOrchestrator.from_events()
      |> PaneOrchestrator.graph()

    acp_edge_ids = acp.graph.edges |> Map.keys() |> MapSet.new()
    pane_edge_ids = pane_graph.edges |> Enum.map(& &1.id) |> MapSet.new()

    assert MapSet.member?(
             acp_edge_ids,
             "mcp-parent:parent-parity-1->child-session:child-parity-1"
           )

    assert MapSet.subset?(pane_edge_ids, acp_edge_ids)
  end

  test "projects decision request resolution into the same decision record" do
    projection =
      Projection.new()
      |> Projection.apply_runtime_event(%{
        type: :parent_call_event,
        parent_call_id: "parent-decision-proj",
        runtime_source: "grok",
        transport: :stdio,
        notification: %{
          "method" => "tools/call",
          "params" => %{
            "name" => "request_user_input",
            "arguments" => %{
              "requestId" => "decision-proj-1",
              "questions" => [
                %{
                  "id" => "scope",
                  "header" => "Scope",
                  "question" => "Pick scope",
                  "options" => [
                    %{"label" => "Narrow", "description" => "Small fix"},
                    %{"label" => "Broad", "description" => "Full pass"}
                  ]
                }
              ]
            }
          }
        }
      })
      |> Projection.apply_runtime_event(%{
        type: :decision_answered,
        decision_id: "decision-proj-1",
        parent_call_id: "parent-decision-proj",
        runtime_source: "ourocode",
        transport: :local,
        selected_label: "Narrow"
      })

    assert %{status: :answered, selected_label: "Narrow", question_count: 1} =
             projection.decisions["decision-proj-1"]
  end
end
