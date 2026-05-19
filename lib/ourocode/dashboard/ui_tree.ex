defmodule Ourocode.Dashboard.UITree do
  @moduledoc """
  Canonical dashboard tree for MCP runtime visibility.

  The tree is transport-neutral: callers feed normalized lifecycle events or
  already-built pane states, and the projection always exposes the same
  parent-call -> child-session -> stream-event node shape.
  """

  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Dashboard.ParentMcpPane

  @type pane_state :: %{
          required(:working) => list(map()),
          required(:completed) => list(map()),
          required(:focused) => String.t() | nil,
          required(:open) => list(String.t())
        }

  @type state :: %{
          required(:parents) => pane_state(),
          required(:children) => pane_state()
        }

  @type tree :: %{
          required(:id) => :ourocode_ui_tree,
          required(:kind) => :ui_tree,
          required(:roots) => list(map()),
          required(:orphan_children) => list(map())
        }

  @doc """
  Returns an empty UI tree accumulator.
  """
  @spec new() :: state()
  def new do
    %{
      parents: %{working: [], completed: [], focused: nil, open: []},
      children: %{working: [], completed: [], focused: nil, open: []}
    }
  end

  @doc """
  Applies one normalized lifecycle event to the canonical tree accumulator.
  """
  @spec apply_event(state(), map()) :: state()
  def apply_event(%{parents: parents, children: children} = state, event) when is_map(event) do
    event = normalize_lifecycle_event(event)

    %{
      state
      | parents: maybe_apply_parent_event(parents, event),
        children: ChildSessionPanes.apply_event(children, event)
    }
  end

  @doc """
  Builds the canonical UI tree from normalized lifecycle events.
  """
  @spec from_events([map()]) :: tree()
  def from_events(events) when is_list(events) do
    events
    |> Enum.reduce(new(), &apply_event(&2, &1))
    |> to_tree()
  end

  @doc """
  Builds the canonical UI tree from pane projections.
  """
  @spec from_panes(pane_state() | map(), pane_state() | map()) :: tree()
  def from_panes(parent_state, child_state) when is_map(parent_state) and is_map(child_state) do
    %{parents: parent_state, children: child_state}
    |> to_tree()
  end

  @doc """
  Converts an accumulator into the render-agnostic canonical UI tree.
  """
  @spec to_tree(state()) :: tree()
  def to_tree(%{parents: parent_state, children: child_state})
      when is_map(parent_state) and is_map(child_state) do
    parents = parent_panes(parent_state)
    children = child_panes(child_state)
    parent_ids = parents |> Enum.map(& &1.parent_call_id) |> MapSet.new()
    children_by_parent = Enum.group_by(children, & &1.parent_call_id)

    %{
      id: :ourocode_ui_tree,
      kind: :ui_tree,
      roots:
        Enum.map(parents, fn parent ->
          children =
            children_by_parent
            |> Map.get(parent.parent_call_id, [])
            |> Enum.map(&child_node/1)

          parent
          |> parent_node()
          |> Map.put(:children, children)
        end),
      orphan_children:
        children
        |> Enum.reject(fn child -> MapSet.member?(parent_ids, child.parent_call_id) end)
        |> Enum.map(&child_node/1)
    }
  end

  defp parent_panes(%{kind: :parent_mcp_call} = pane), do: [pane]

  defp parent_panes(%{working: working, completed: completed})
       when is_list(working) and is_list(completed),
       do: working ++ completed

  defp parent_panes(_state), do: []

  defp child_panes(%{kind: :child_session} = pane), do: [pane]

  defp child_panes(%{working: working, completed: completed})
       when is_list(working) and is_list(completed),
       do: working ++ completed

  defp child_panes(_state), do: []

  defp maybe_apply_parent_event(parents, %{type: :parent_call_event} = event) do
    if child_stream_event?(event) and not parent_known?(parents, Map.get(event, :parent_call_id)) do
      parents
    else
      ParentMcpPane.apply_event(parents, event)
    end
  end

  defp maybe_apply_parent_event(parents, event), do: ParentMcpPane.apply_event(parents, event)

  defp parent_known?(_parents, nil), do: false

  defp parent_known?(parents, parent_call_id) do
    parents
    |> parent_panes()
    |> Enum.any?(&(&1.parent_call_id == parent_call_id))
  end

  defp child_stream_event?(event) do
    not is_nil(child_id_from_external_ids(event) || child_id_from_payload(event))
  end

  defp child_id_from_external_ids(event) do
    case Map.get(event, :external_ids) do
      ids when is_map(ids) ->
        Map.get(ids, :childID) ||
          Map.get(ids, "childID") ||
          Map.get(ids, :child_id) ||
          Map.get(ids, "child_id")

      _ ->
        nil
    end
  end

  defp child_id_from_payload(event) do
    event
    |> stream_payload()
    |> case do
      payload when is_map(payload) ->
        Map.get(payload, "childID") ||
          Map.get(payload, :childID) ||
          Map.get(payload, "child_id") ||
          Map.get(payload, :child_id)

      _ ->
        nil
    end
  end

  defp stream_payload(event) do
    Map.get(event, :payload) ||
      get_in(event, [:notification, "params"]) ||
      get_in(event, [:notification, :params]) ||
      get_in(event, [:raw_event, "data", "params"]) ||
      get_in(event, [:raw_event, :data, :params])
  end

  defp normalize_lifecycle_event(%_{} = event) do
    event
    |> Map.from_struct()
    |> normalize_lifecycle_event()
  end

  defp normalize_lifecycle_event(event) when is_map(event) do
    %{}
    |> maybe_put(:event_seq, integer_value(event, :event_seq))
    |> maybe_put(:type, lifecycle_type(event))
    |> maybe_put(:pane_id, string_value(event, :pane_id) || string_value(event, :id))
    |> maybe_put(:child_id, string_value(event, :child_id))
    |> maybe_put(:transport, transport(event))
    |> maybe_put(:parent_call_id, string_value(event, :parent_call_id))
    |> maybe_put(:runtime_source, string_value(event, :runtime_source))
    |> maybe_put(:external_ids, map_value(event, :external_ids, %{}))
    |> maybe_put(:stream_cursor, map_value(event, :stream_cursor, nil))
    |> maybe_put(:pane_state, map_value(event, :pane_state, nil))
    |> maybe_put(:occurred_at_ms, integer_value(event, :occurred_at_ms))
    |> maybe_put(:created_at_ms, integer_value(event, :created_at_ms))
    |> maybe_put(:updated_at_ms, integer_value(event, :updated_at_ms))
    |> maybe_put(:call_id, string_value(event, :call_id))
    |> maybe_put(:request_id, string_value(event, :request_id))
    |> maybe_put(:method, string_value(event, :method))
    |> maybe_put(:params, value(event, :params))
    |> maybe_put(:payload, value(event, :payload))
    |> maybe_put(:result, value(event, :result))
    |> maybe_put(:error, value(event, :error))
    |> maybe_put(:error_details, value(event, :error_details))
    |> maybe_put(:notification, map_value(event, :notification, nil))
    |> maybe_put(:status, integer_value(event, :status))
    |> maybe_put(:headers, value(event, :headers))
    |> maybe_put(:raw_event, map_value(event, :raw_event, nil))
  end

  @lifecycle_types MapSet.new([
                     :parent_call_started,
                     :parent_call_event,
                     :parent_call_result,
                     :parent_call_failed,
                     :parent_call_write_failed,
                     :parent_call_unmatched_result,
                     :transport_decode_failed,
                     :transport_exited,
                     :transport_connected,
                     :transport_failed,
                     :transport_closed,
                     :transport_started,
                     :child_pane_registered,
                     :child_pane_opened,
                     :child_pane_focused,
                     :child_pane_updated,
                     :child_pane_completed
                   ])

  defp lifecycle_type(event) do
    case value(event, :type) do
      type when is_atom(type) ->
        if MapSet.member?(@lifecycle_types, type), do: type

      type when is_binary(type) ->
        Enum.find(@lifecycle_types, &(Atom.to_string(&1) == type))

      _type ->
        nil
    end
  end

  defp transport(event) do
    case value(event, :transport) do
      transport when transport in [:stdio, :streamable_http, :sse] -> transport
      "stdio" -> :stdio
      "streamable_http" -> :streamable_http
      "sse" -> :sse
      _transport -> nil
    end
  end

  defp value(event, key) do
    Map.get(event, key) || Map.get(event, Atom.to_string(key))
  end

  defp string_value(event, key) do
    case value(event, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _value -> nil
    end
  end

  defp integer_value(event, key) do
    case value(event, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} -> integer
          _ -> nil
        end

      _value ->
        nil
    end
  end

  defp map_value(event, key, default) do
    case value(event, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp parent_node(%{kind: :parent_mcp_call} = pane) do
    %{
      id: pane.id,
      kind: :parent_call,
      pane_kind: :parent_mcp_call,
      status: pane.status,
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: pane.transport,
      external_ids: Map.get(pane, :external_ids, %{}),
      stream_cursor: Map.get(pane, :stream_cursor, %{}),
      pane_state: Map.get(pane, :pane_state, %{}),
      created_at_ms: Map.get(pane, :created_at_ms),
      updated_at_ms: Map.get(pane, :updated_at_ms)
    }
    |> maybe_put(:request_id, Map.get(pane, :request_id))
    |> maybe_put(:method, Map.get(pane, :method))
    |> maybe_put(:params, Map.get(pane, :params))
    |> maybe_put(:result, Map.get(pane, :result))
    |> maybe_put(:error, Map.get(pane, :error))
  end

  defp child_node(%{kind: :child_session} = pane) do
    %{
      id: pane.id,
      kind: :child_session,
      status: pane.status,
      child_id: pane.child_id,
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: pane.transport,
      external_ids: Map.get(pane, :external_ids, %{}),
      stream_cursor: Map.get(pane, :stream_cursor, %{}),
      pane_state: Map.drop(Map.get(pane, :pane_state, %{}), [:stream_entries]),
      stream_events: stream_event_nodes(pane),
      created_at_ms: Map.get(pane, :created_at_ms),
      updated_at_ms: Map.get(pane, :updated_at_ms)
    }
  end

  defp stream_event_nodes(%{
         child_id: child_id,
         parent_call_id: parent_call_id,
         pane_state: pane_state
       })
       when is_map(pane_state) do
    entries =
      case Map.get(pane_state, :stream_entries, []) do
        entries when is_list(entries) -> entries
        _entries -> []
      end

    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} ->
      stream_event_node(parent_call_id, child_id, entry, index)
    end)
  end

  defp stream_event_nodes(_pane), do: []

  defp stream_event_node(parent_call_id, child_id, entry, index) when is_map(entry) do
    event_seq = Map.get(entry, :event_seq, 0)

    %{
      id: "stream-event:" <> child_id <> ":" <> to_string(event_seq) <> ":" <> to_string(index),
      kind: :stream_event,
      parent_call_id: parent_call_id,
      child_id: child_id,
      event_seq: event_seq,
      runtime_seq: Map.get(entry, :runtime_seq),
      type: Map.get(entry, :type),
      token: Map.get(entry, :token),
      delta: Map.get(entry, :delta),
      content: Map.get(entry, :content),
      payload: Map.get(entry, :payload, %{}),
      occurred_at_ms: Map.get(entry, :occurred_at_ms)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
