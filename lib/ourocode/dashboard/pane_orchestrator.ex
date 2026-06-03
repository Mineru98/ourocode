defmodule Ourocode.Dashboard.PaneOrchestrator do
  @moduledoc """
  Folds MCP lifecycle events into parent panes, child panes, and topology.

  This is the dashboard-side orchestration layer for the Grok-like toolcall UX:
  each MCP tool call owns a parent pane, and every child session/job/subagent
  discovered in its stream is represented as a linked child pane.
  """

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Dashboard.ParentMcpPane
  alias Ourocode.MCP.SessionGraph

  @type topology :: %{
          required(:nodes) => map(),
          required(:edges) => map(),
          required(:events) => [map()]
        }

  @type state :: %{
          required(:parents) => ParentMcpPane.pane_state(),
          required(:children) => ChildSessionPanes.pane_state(),
          required(:topology) => topology()
        }

  @doc """
  Returns a fresh pane orchestration state.
  """
  @spec new() :: state()
  def new do
    %{
      parents: ParentMcpPane.new(),
      children: ChildSessionPanes.new(),
      topology: new_topology()
    }
  end

  @doc """
  Builds orchestration state by replaying normalized lifecycle events.
  """
  @spec from_events([map()]) :: state()
  def from_events(events) when is_list(events) do
    Enum.reduce(events, new(), &apply_event(&2, &1))
  end

  @doc """
  Applies one normalized lifecycle event to parent panes, child panes, and graph.
  """
  @spec apply_event(map(), map()) :: map()
  def apply_event(state, event) when is_map(state) and is_map(event) do
    state = normalize_state(state)

    %{
      state
      | parents: ParentMcpPane.apply_event(state.parents, event),
        children: ChildSessionPanes.apply_event(state.children, event),
        topology: apply_topology_events(state.topology, SessionGraph.topology_events(event))
    }
  end

  @doc """
  Returns a render-agnostic parent/child graph snapshot.
  """
  @spec graph(state() | map()) :: map()
  def graph(state) when is_map(state) do
    topology = state |> normalize_state() |> Map.fetch!(:topology)

    %{
      nodes:
        topology.nodes
        |> Map.values()
        |> Enum.sort_by(&{node_order(&1), Map.get(&1, :first_event_seq, 0), &1.id}),
      edges:
        topology.edges
        |> Map.values()
        |> Enum.sort_by(&{Map.get(&1, :first_event_seq, 0), &1.id}),
      events: topology.events
    }
  end

  @doc """
  Returns the current parent pane state from a possibly partial orchestrator state.
  """
  @spec parent_state(map()) :: ParentMcpPane.pane_state()
  def parent_state(state), do: state |> normalize_state() |> Map.fetch!(:parents)

  @doc """
  Returns the current child pane state from a possibly partial orchestrator state.
  """
  @spec child_state(map()) :: ChildSessionPanes.pane_state()
  def child_state(state), do: state |> normalize_state() |> Map.fetch!(:children)

  @doc """
  Returns the current topology accumulator from a possibly partial state.
  """
  @spec topology_state(map()) :: topology()
  def topology_state(state), do: state |> normalize_state() |> Map.fetch!(:topology)

  @spec new_topology() :: topology()
  def new_topology, do: %{nodes: %{}, edges: %{}, events: []}

  defp normalize_state(%{parents: parents, children: children, topology: topology} = state)
       when is_map(parents) and is_map(children) and is_map(topology) do
    %{
      state
      | parents: normalize_parent_state(parents),
        children: normalize_child_state(children),
        topology: normalize_topology(topology)
    }
  end

  defp normalize_state(%{parent: parents, child: children} = state)
       when is_map(parents) and is_map(children) do
    %{
      parents: normalize_parent_state(parents),
      children: normalize_child_state(children),
      topology: normalize_topology(Map.get(state, :mcp_topology, new_topology()))
    }
  end

  defp normalize_state(_state), do: new()

  defp normalize_topology(%{nodes: nodes, edges: edges, events: events})
       when is_map(nodes) and is_map(edges) and is_list(events) do
    %{nodes: nodes, edges: edges, events: events}
  end

  defp normalize_topology(_topology), do: new_topology()

  defp normalize_parent_state(%{
         working: working,
         completed: completed,
         focused: focused,
         open: open
       })
       when is_list(working) and is_list(completed) and is_list(open) do
    %{working: working, completed: completed, focused: focused, open: open}
  end

  defp normalize_parent_state(_state), do: ParentMcpPane.new()

  defp normalize_child_state(
         %{working: working, completed: completed, focused: focused, open: open} = state
       )
       when is_list(working) and is_list(completed) and is_list(open) do
    %{
      working: working,
      completed: completed,
      focused: focused,
      open: open,
      child_pane_registry: Map.get(state, :child_pane_registry, %{})
    }
  end

  defp normalize_child_state(_state), do: ChildSessionPanes.new()

  defp apply_topology_events(topology, []), do: topology

  defp apply_topology_events(topology, events) do
    Enum.reduce(events, topology, &apply_topology_event(&2, &1))
  end

  defp apply_topology_event(topology, %{type: :mcp_parent_call_seen, node_id: node_id} = event) do
    upsert_node(topology, node_id, %{
      id: node_id,
      kind: :parent_call,
      parent_call_id: event.parent_call_id,
      runtime_source: Map.get(event, :runtime_source),
      transport: Map.get(event, :transport),
      lifecycle_type: Map.get(event, :lifecycle_type),
      first_event_seq: Map.get(event, :event_seq),
      latest_event_seq: Map.get(event, :event_seq),
      updated_at_ms: Map.get(event, :occurred_at_ms)
    })
    |> append_topology_event(event)
  end

  defp apply_topology_event(topology, %{type: :mcp_child_session_seen, node_id: node_id} = event) do
    upsert_node(topology, node_id, %{
      id: node_id,
      kind: :child_session,
      child_id: event.child_id,
      parent_call_id: event.parent_call_id,
      pane_key: Map.get(event, :pane_key),
      id_source: Map.get(event, :id_source),
      payload_path: Map.get(event, :payload_path),
      runtime_source: Map.get(event, :runtime_source),
      transport: Map.get(event, :transport),
      first_event_seq: Map.get(event, :event_seq),
      latest_event_seq: Map.get(event, :event_seq),
      updated_at_ms: Map.get(event, :occurred_at_ms)
    })
    |> append_topology_event(event)
  end

  defp apply_topology_event(topology, %{type: :mcp_parent_child_linked, edge_id: edge_id} = event) do
    upsert_edge(topology, edge_id, %{
      id: edge_id,
      kind: :parent_child,
      from: event.from,
      to: event.to,
      parent_call_id: event.parent_call_id,
      child_id: event.child_id,
      runtime_source: Map.get(event, :runtime_source),
      transport: Map.get(event, :transport),
      first_event_seq: Map.get(event, :event_seq),
      latest_event_seq: Map.get(event, :event_seq),
      updated_at_ms: Map.get(event, :occurred_at_ms)
    })
    |> append_topology_event(event)
  end

  defp apply_topology_event(topology, event), do: append_topology_event(topology, event)

  defp upsert_node(topology, id, node) do
    nodes = Map.update(topology.nodes, id, drop_nil_values(node), &merge_topology_entry(&1, node))
    %{topology | nodes: nodes}
  end

  defp upsert_edge(topology, id, edge) do
    edges = Map.update(topology.edges, id, drop_nil_values(edge), &merge_topology_entry(&1, edge))
    %{topology | edges: edges}
  end

  defp merge_topology_entry(existing, incoming) do
    incoming = drop_nil_values(incoming)

    existing
    |> Map.merge(incoming)
    |> Map.put(
      :first_event_seq,
      min_present(existing[:first_event_seq], incoming[:first_event_seq])
    )
    |> Map.put(
      :latest_event_seq,
      max_present(existing[:latest_event_seq], incoming[:latest_event_seq])
    )
  end

  defp append_topology_event(topology, event) do
    %{topology | events: topology.events ++ [event]}
  end

  defp min_present(nil, value), do: value
  defp min_present(value, nil), do: value
  defp min_present(left, right), do: min(left, right)

  defp max_present(nil, value), do: value
  defp max_present(value, nil), do: value
  defp max_present(left, right), do: max(left, right)

  defp node_order(%{kind: :parent_call}), do: 0
  defp node_order(%{kind: :child_session}), do: 1
  defp node_order(_node), do: 2

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
