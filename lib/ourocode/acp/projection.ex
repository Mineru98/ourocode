defmodule Ourocode.ACP.Projection do
  @moduledoc """
  Data projection for the Agent Control Plane.

  This store is intentionally render-neutral. Terminal panes, headless JSON
  streams, and future ACP stdio adapters should all be able to consume the same
  sessions/tool-calls/decisions graph.
  """

  alias Ourocode.ACP.Event

  @max_events 200

  @type t :: %{
          required(:events) => [Event.t()],
          required(:workflow_runs) => map(),
          required(:tool_calls) => map(),
          required(:agent_sessions) => map(),
          required(:decisions) => map(),
          required(:graph) => map()
        }

  @spec new() :: t()
  def new do
    %{
      events: [],
      workflow_runs: %{},
      tool_calls: %{},
      agent_sessions: %{},
      decisions: %{},
      graph: %{nodes: %{}, edges: %{}}
    }
  end

  @spec apply_runtime_event(t() | map() | nil, map()) :: t()
  def apply_runtime_event(projection, runtime_event) when is_map(runtime_event) do
    projection = normalize(projection)

    runtime_event
    |> Event.from_runtime_event()
    |> Enum.reduce(projection, &apply_event(&2, &1))
  end

  def apply_runtime_event(projection, _runtime_event), do: normalize(projection)

  @spec apply_event(t() | map() | nil, Event.t()) :: t()
  def apply_event(projection, %{kind: :acp_event} = event) do
    projection
    |> normalize()
    |> append_event(event)
    |> apply_typed_event(event)
  end

  def apply_event(projection, _event), do: normalize(projection)

  defp apply_typed_event(projection, %{type: :workflow_run, workflow_run_id: id} = event) do
    node_id = workflow_node_id(id)

    projection
    |> put_in([:workflow_runs, id], merge_record(Map.get(projection.workflow_runs, id), event))
    |> upsert_node(node_id, :workflow_run, event)
    |> maybe_link_run_parent(event)
  end

  defp apply_typed_event(projection, %{type: :tool_call, parent_call_id: id} = event) do
    projection
    |> put_in([:tool_calls, id], merge_record(Map.get(projection.tool_calls, id), event))
    |> upsert_node(parent_node_id(id), :tool_call, event)
  end

  defp apply_typed_event(projection, %{type: :agent_session, child_id: id} = event) do
    projection
    |> put_in([:agent_sessions, id], merge_record(Map.get(projection.agent_sessions, id), event))
    |> upsert_node(child_node_id(id), :agent_session, event)
    |> maybe_link_parent_child(event)
  end

  defp apply_typed_event(projection, %{type: :decision_request, decision_id: id} = event) do
    projection
    |> put_in([:decisions, id], merge_record(Map.get(projection.decisions, id), event))
    |> upsert_node("decision:" <> id, :decision_request, event)
    |> maybe_link_decision(event)
  end

  defp apply_typed_event(projection, %{type: :decision_result, decision_id: id} = event) do
    projection
    |> put_in([:decisions, id], merge_record(Map.get(projection.decisions, id), event))
    |> upsert_node("decision:" <> id, :decision_request, event)
    |> maybe_link_decision(event)
  end

  defp apply_typed_event(projection, _event), do: projection

  defp append_event(projection, event) do
    %{projection | events: [event | projection.events] |> Enum.take(@max_events)}
  end

  defp merge_record(nil, event), do: event

  defp merge_record(existing, event) do
    existing
    |> Map.merge(event)
    |> Map.put(:first_event_seq, min_present(existing[:first_event_seq], event[:event_seq]))
    |> Map.put(:latest_event_seq, max_present(existing[:latest_event_seq], event[:event_seq]))
    |> Map.put(:updated_at_ms, event[:occurred_at_ms] || existing[:updated_at_ms])
  end

  defp upsert_node(projection, node_id, kind, event) do
    node =
      %{
        id: node_id,
        kind: kind,
        status: Map.get(event, :status),
        runtime_source: Map.get(event, :runtime_source),
        transport: Map.get(event, :transport),
        first_event_seq: Map.get(event, :event_seq),
        latest_event_seq: Map.get(event, :event_seq),
        updated_at_ms: Map.get(event, :occurred_at_ms)
      }
      |> maybe_put(:parent_call_id, Map.get(event, :parent_call_id))
      |> maybe_put(:child_id, Map.get(event, :child_id))
      |> maybe_put(:decision_id, Map.get(event, :decision_id))
      |> drop_nil_values()

    update_in(projection.graph.nodes, fn nodes ->
      Map.update(nodes, node_id, node, &merge_record(&1, node))
    end)
  end

  defp maybe_link_parent_child(projection, %{parent_call_id: parent_id, child_id: child_id}) do
    edge_id = parent_node_id(parent_id) <> "->" <> child_node_id(child_id)

    upsert_edge(projection, edge_id, %{
      id: edge_id,
      kind: :parent_child,
      from: parent_node_id(parent_id),
      to: child_node_id(child_id),
      parent_call_id: parent_id,
      child_id: child_id
    })
  end

  defp maybe_link_parent_child(projection, _event), do: projection

  defp maybe_link_run_parent(projection, %{
         workflow_run_id: run_id,
         parent_call_id: parent_call_id
       })
       when is_binary(run_id) and is_binary(parent_call_id) do
    run_node_id = workflow_node_id(run_id)
    edge_id = run_node_id <> "->" <> parent_node_id(parent_call_id)

    upsert_edge(projection, edge_id, %{
      id: edge_id,
      kind: :run_parent_call,
      from: run_node_id,
      to: parent_node_id(parent_call_id),
      workflow_run_id: run_id,
      parent_call_id: parent_call_id
    })
  end

  defp maybe_link_run_parent(projection, _event), do: projection

  defp maybe_link_decision(projection, %{parent_call_id: parent_id, decision_id: decision_id})
       when is_binary(parent_id) and is_binary(decision_id) do
    edge_id = parent_node_id(parent_id) <> "->decision:" <> decision_id

    upsert_edge(projection, edge_id, %{
      id: edge_id,
      kind: :parent_decision,
      from: parent_node_id(parent_id),
      to: "decision:" <> decision_id,
      parent_call_id: parent_id,
      decision_id: decision_id
    })
  end

  defp maybe_link_decision(projection, _event), do: projection

  defp workflow_node_id("workflow-run:" <> _rest = id), do: id
  defp workflow_node_id(id), do: "workflow-run:" <> id
  defp parent_node_id(parent_call_id), do: "mcp-parent:" <> parent_call_id
  defp child_node_id(child_id), do: "child-session:" <> child_id

  defp upsert_edge(projection, edge_id, edge) do
    update_in(projection.graph.edges, fn edges ->
      Map.update(edges, edge_id, edge, &Map.merge(&1, edge))
    end)
  end

  defp normalize(%{
         events: events,
         workflow_runs: workflow_runs,
         tool_calls: tool_calls,
         agent_sessions: sessions,
         decisions: decisions,
         graph: graph
       })
       when is_list(events) and is_map(workflow_runs) and is_map(tool_calls) and
              is_map(sessions) and is_map(decisions) and is_map(graph) do
    %{
      events: events,
      workflow_runs: workflow_runs,
      tool_calls: tool_calls,
      agent_sessions: sessions,
      decisions: decisions,
      graph: normalize_graph(graph)
    }
  end

  defp normalize(_projection), do: new()

  defp normalize_graph(%{nodes: nodes, edges: edges}) when is_map(nodes) and is_map(edges),
    do: %{nodes: nodes, edges: edges}

  defp normalize_graph(_graph), do: %{nodes: %{}, edges: %{}}

  defp min_present(nil, value), do: value
  defp min_present(value, nil), do: value
  defp min_present(left, right), do: min(left, right)

  defp max_present(nil, value), do: value
  defp max_present(value, nil), do: value
  defp max_present(left, right), do: max(left, right)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
