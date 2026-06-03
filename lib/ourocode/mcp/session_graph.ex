defmodule Ourocode.MCP.SessionGraph do
  @moduledoc """
  Converts MCP lifecycle events into parent/child topology events.

  This is the transport-neutral bridge between an MCP `tools/call` and the live
  pane graph: one parent call can emit any number of child sessions, and each
  child is linked back to the parent by `parent_call_id`.
  """

  alias Ourocode.MCP.ChildSessionCreationParser

  @parent_call_types [
    :parent_call_started,
    :parent_call_event,
    :parent_call_result,
    :parent_call_failed,
    :parent_call_unmatched_result
  ]

  @child_call_types [:parent_call_started, :parent_call_event, :parent_call_result]

  @type topology_event :: %{
          required(:type) => atom(),
          required(:parent_call_id) => String.t(),
          optional(:child_id) => String.t(),
          optional(:node_id) => String.t(),
          optional(:edge_id) => String.t()
        }

  @spec topology_events(map() | struct() | term()) :: [topology_event()]
  def topology_events(%_{} = event), do: event |> Map.from_struct() |> topology_events()

  def topology_events(event) when is_map(event) do
    parent = parent_node_event(event)
    child_events = child_topology_events(event)

    [parent | child_events]
    |> Enum.reject(&is_nil/1)
  end

  def topology_events(_event), do: []

  @spec parent_node_event(map()) :: topology_event() | nil
  def parent_node_event(event) when is_map(event) do
    with true <- Map.get(event, :type) in @parent_call_types,
         {:ok, parent_call_id} <- string_field(event, :parent_call_id) do
      %{
        type: :mcp_parent_call_seen,
        node_id: parent_node_id(parent_call_id),
        parent_call_id: parent_call_id,
        lifecycle_type: Map.get(event, :type),
        runtime_source: string_field_or_nil(event, :runtime_source),
        transport: Map.get(event, :transport),
        event_seq: Map.get(event, :event_seq),
        occurred_at_ms: Map.get(event, :occurred_at_ms)
      }
      |> drop_nil_values()
    else
      _value -> nil
    end
  end

  def parent_node_event(_event), do: nil

  @spec child_topology_events(map()) :: [topology_event()]
  def child_topology_events(event) when is_map(event) do
    with true <- Map.get(event, :type) in @child_call_types,
         {:ok, parent_call_id} <- string_field(event, :parent_call_id),
         {:ok, extraction} <- child_extraction(event) do
      child_id = extraction.child_id
      child_node_id = child_node_id(child_id)

      [
        %{
          type: :mcp_child_session_seen,
          node_id: child_node_id,
          child_id: child_id,
          parent_call_id: parent_call_id,
          pane_key: extraction.pane_key,
          id_source: extraction.source,
          payload_path: extraction.payload_path,
          runtime_source: string_field_or_nil(event, :runtime_source),
          transport: Map.get(event, :transport),
          event_seq: Map.get(event, :event_seq),
          occurred_at_ms: Map.get(event, :occurred_at_ms)
        },
        %{
          type: :mcp_parent_child_linked,
          edge_id: parent_child_edge_id(parent_call_id, child_id),
          from: parent_node_id(parent_call_id),
          to: child_node_id,
          parent_call_id: parent_call_id,
          child_id: child_id,
          runtime_source: string_field_or_nil(event, :runtime_source),
          transport: Map.get(event, :transport),
          event_seq: Map.get(event, :event_seq),
          occurred_at_ms: Map.get(event, :occurred_at_ms)
        }
      ]
      |> Enum.map(&drop_nil_values/1)
    else
      _value -> []
    end
  end

  def child_topology_events(_event), do: []

  @spec parent_node_id(String.t()) :: String.t()
  def parent_node_id(parent_call_id), do: "mcp-parent:" <> parent_call_id

  @spec child_node_id(String.t()) :: String.t()
  def child_node_id(child_id), do: "child-session:" <> child_id

  @spec parent_child_edge_id(String.t(), String.t()) :: String.t()
  def parent_child_edge_id(parent_call_id, child_id),
    do: parent_node_id(parent_call_id) <> "->" <> child_node_id(child_id)

  defp child_extraction(event) do
    case ChildSessionCreationParser.extract(event) do
      {:ok, extraction} -> {:ok, extraction}
      _other -> :error
    end
  end

  defp string_field(event, key) do
    case Map.get(event, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> :error
    end
  end

  defp string_field_or_nil(event, key) do
    case string_field(event, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
