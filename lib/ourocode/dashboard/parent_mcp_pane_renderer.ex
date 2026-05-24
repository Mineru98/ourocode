defmodule Ourocode.Dashboard.ParentMcpPaneRenderer do
  @moduledoc """
  Pure rendering for parent MCP pane projections.
  """

  @spec render(map()) :: map()
  def render(%{kind: :parent_mcp_call} = pane) do
    lifecycle = get_in(pane, [:pane_state, :lifecycle_type])
    event_count = get_in(pane, [:pane_state, :event_count]) || 0
    notification_count = get_in(pane, [:pane_state, :notification_count]) || 0
    child_id = child_id(pane.external_ids)

    rendered = %{
      id: pane.id,
      kind: :parent_mcp_call,
      title: "Parent MCP",
      status: Atom.to_string(pane.status),
      lifecycle: stringify(lifecycle, "unknown"),
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: Atom.to_string(pane.transport),
      request_id: Map.get(pane, :request_id),
      method: Map.get(pane, :method),
      child_id: child_id,
      external_ids: pane.external_ids,
      stream_cursor: pane.stream_cursor,
      event_count: event_count,
      notification_count: notification_count,
      updated_at_ms: pane.updated_at_ms
    }

    Map.put(rendered, :line, line(rendered))
  end

  @spec line(map()) :: String.t()
  def line(%{line: line}) when is_binary(line), do: line

  def line(%{kind: :parent_mcp_call, status: status} = pane) when is_atom(status) do
    pane
    |> render()
    |> Map.fetch!(:line)
  end

  def line(rendered) when is_map(rendered) do
    [
      "[#{rendered.status}]",
      "parent=#{rendered.parent_call_id}",
      "lifecycle=#{rendered.lifecycle}",
      "runtime=#{rendered.runtime_source}",
      "transport=#{rendered.transport}",
      maybe_segment("request", rendered.request_id),
      maybe_segment("method", rendered.method),
      maybe_segment("child", rendered.child_id),
      "seq=#{rendered.stream_cursor.event_seq}",
      "events=#{rendered.event_count}",
      "notifications=#{rendered.notification_count}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp child_id(external_ids) do
    external_ids
    |> case do
      ids when is_map(ids) ->
        Map.get(ids, :child_id) ||
          Map.get(ids, "child_id") ||
          Map.get(ids, :childID) ||
          Map.get(ids, "childID")

      _ ->
        nil
    end
    |> case do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> nil
    end
  end

  defp maybe_segment(_key, nil), do: nil
  defp maybe_segment(_key, ""), do: nil
  defp maybe_segment(key, value), do: key <> "=" <> to_string(value)

  defp stringify(nil, default), do: default
  defp stringify(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value, _default), do: to_string(value)
end
