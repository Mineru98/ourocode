defmodule Ourocode.Dashboard.ParentMcpPaneUpdate do
  @moduledoc """
  Applies safe update payloads to first-class parent MCP panes.

  Pane identity fields are intentionally immutable so dashboard updates cannot
  orphan focus/open state or create duplicate panes for a parent call.
  """

  alias Ourocode.Dashboard.ParentMcpPaneMetadata, as: Metadata

  @spec apply(map(), map()) :: map()
  def apply(%{kind: :parent_mcp_call} = pane, updates) when is_map(updates) do
    pane
    |> maybe_update_scalar(:status, updates, &Metadata.normalize_status/1)
    |> maybe_update_scalar(:runtime_source, updates, &Metadata.normalize_string/1)
    |> maybe_update_scalar(:transport, updates, &Metadata.normalize_transport/1)
    |> maybe_update_scalar(:request_id, updates, &Metadata.normalize_optional_string/1)
    |> maybe_update_scalar(:method, updates, &Metadata.normalize_optional_string/1)
    |> maybe_update_value(:params, updates)
    |> maybe_update_value(:result, updates)
    |> maybe_update_value(:error, updates)
    |> maybe_update_value(:notification, updates)
    |> maybe_merge_map(:external_ids, updates)
    |> maybe_merge_map(:stream_cursor, updates)
    |> maybe_merge_map(:pane_state, updates)
    |> maybe_update_scalar(:updated_at_ms, updates, &Metadata.normalize_integer/1)
    |> Map.put(:id, pane.id)
    |> Map.put(:kind, :parent_mcp_call)
    |> Map.put(:parent_call_id, pane.parent_call_id)
    |> Map.put(:created_at_ms, pane.created_at_ms)
    |> ensure_stream_cursor_identity()
  end

  defp ensure_stream_cursor_identity(pane) do
    stream_cursor =
      pane.stream_cursor
      |> Map.put(:transport, pane.transport)
      |> Map.put(:parent_call_id, pane.parent_call_id)

    Map.put(pane, :stream_cursor, stream_cursor)
  end

  defp maybe_update_scalar(pane, key, updates, normalizer) do
    case Metadata.value(updates, key) do
      nil ->
        pane

      value ->
        case normalizer.(value) do
          nil -> pane
          normalized -> Map.put(pane, key, normalized)
        end
    end
  end

  defp maybe_update_value(pane, key, updates) do
    if Map.has_key?(updates, key) or Map.has_key?(updates, Atom.to_string(key)) do
      Map.put(pane, key, Metadata.value(updates, key))
    else
      pane
    end
  end

  defp maybe_merge_map(pane, key, updates) do
    case Metadata.value(updates, key) do
      value when is_map(value) -> Map.put(pane, key, Map.merge(Map.get(pane, key, %{}), value))
      _value -> pane
    end
  end
end
