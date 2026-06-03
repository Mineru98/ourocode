defmodule Ourocode.Dashboard.LayoutRuntimeHierarchy do
  @moduledoc """
  Builds and renders parent/child MCP runtime hierarchy projections.
  """

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane, ScrollbackLedger}

  @spec build(map(), map()) :: map()
  def build(parent_state, child_state) when is_map(parent_state) and is_map(child_state) do
    parents = rendered_parent_panes(parent_state)
    children = child_panes(child_state)
    parent_ids = parents |> Enum.map(& &1.parent_call_id) |> MapSet.new()
    children_by_parent = Enum.group_by(children, & &1.parent_call_id)

    %{
      id: :mcp_runtime_hierarchy,
      roots:
        Enum.map(parents, fn parent ->
          children =
            children_by_parent
            |> Map.get(parent.parent_call_id, [])
            |> Enum.map(&render_child/1)

          Map.put(parent, :children, children)
        end),
      orphan_children:
        children
        |> Enum.reject(fn child -> MapSet.member?(parent_ids, child.parent_call_id) end)
        |> Enum.map(&render_child/1)
    }
  end

  @spec render_frame(map()) :: String.t()
  def render_frame(%{id: :mcp_runtime_hierarchy, roots: roots, orphan_children: orphans})
      when is_list(roots) and is_list(orphans) do
    root_lines =
      roots
      |> Enum.flat_map(fn root ->
        child_lines =
          root
          |> Map.get(:children, [])
          |> Enum.map(&child_frame_line/1)

        [parent_frame_line(root) | child_lines]
      end)

    orphan_lines =
      case orphans do
        [] -> []
        children -> ["Orphan Child Sessions" | Enum.map(children, &child_frame_line/1)]
      end

    (["MCP Runtime"] ++ root_lines ++ orphan_lines)
    |> Enum.join("\n")
  end

  defp rendered_parent_panes(%{kind: :parent_mcp_call} = pane), do: [ParentMcpPane.render(pane)]

  defp rendered_parent_panes(%{working: working, completed: completed} = state)
       when is_list(working) and is_list(completed) do
    rendered = ParentMcpPane.render(state)
    rendered.working ++ rendered.completed
  end

  defp rendered_parent_panes(_state), do: []

  defp child_panes(%{working: working, completed: completed})
       when is_list(working) and is_list(completed),
       do: working ++ completed

  defp child_panes(_state), do: []

  defp render_child(%{kind: :child_session} = pane) do
    rendered = ChildSessionPanes.render(pane)

    %{
      id: pane.id,
      kind: pane.kind,
      title: rendered.title,
      line: rendered.line,
      status: Atom.to_string(pane.status),
      child_id: pane.child_id,
      parent_call_id: pane.parent_call_id,
      runtime_source: pane.runtime_source,
      transport: Atom.to_string(pane.transport),
      external_ids: pane.external_ids,
      stream_cursor: pane.stream_cursor,
      pane_state: pane.pane_state,
      stream_entries: stream_entries(pane),
      scrollback_ledger: rendered.scrollback_ledger,
      stream_event_count: rendered.stream_event_count,
      ledger_block_count: rendered.ledger_block_count,
      updated_at_ms: pane.updated_at_ms
    }
  end

  defp parent_frame_line(%{kind: :parent_mcp_call} = parent) do
    ParentMcpPane.render_line(parent)
  end

  defp child_frame_line(%{kind: :child_session, line: line} = child) when is_binary(line) do
    [
      "  " <> line,
      title_segment(child),
      ledger_segment(child),
      stream_segment(child)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp title_segment(%{title: title}) when is_binary(title) and title != "" do
    "title=" <> inspect(title)
  end

  defp title_segment(_child), do: nil

  defp ledger_segment(%{scrollback_ledger: %{blocks: blocks}})
       when is_list(blocks) and blocks != [] do
    summaries =
      blocks
      |> Enum.map(&ledger_block_summary/1)
      |> Enum.reject(&(&1 == ""))

    case summaries do
      [] -> nil
      summaries -> "ledger=[" <> Enum.join(summaries, "|") <> "]"
    end
  end

  defp ledger_segment(_child), do: nil

  defp ledger_block_summary(block) when is_map(block) do
    block
    |> ScrollbackLedger.render_block_line()
    |> String.replace("|", "/")
  end

  defp ledger_block_summary(_block), do: ""

  defp stream_segment(%{stream_entries: entries}) when is_list(entries) and entries != [] do
    summaries =
      entries
      |> Enum.map(&stream_entry_summary/1)
      |> Enum.reject(&(&1 == ""))

    case summaries do
      [] -> nil
      summaries -> "stream=[" <> Enum.join(summaries, "|") <> "]"
    end
  end

  defp stream_segment(_child), do: nil

  defp stream_entry_summary(entry) when is_map(entry) do
    seq =
      Map.get(entry, :runtime_seq) ||
        Map.get(entry, "runtime_seq") ||
        Map.get(entry, :event_seq) ||
        Map.get(entry, "event_seq")

    content_segments =
      [
        value_segment("token", Map.get(entry, :token) || Map.get(entry, "token")),
        value_segment("delta", Map.get(entry, :delta) || Map.get(entry, "delta")),
        value_segment("content", Map.get(entry, :content) || Map.get(entry, "content")),
        media_segment(Map.get(entry, :media_placeholders) || Map.get(entry, "media_placeholders"))
      ]
      |> Enum.reject(&is_nil/1)

    case {seq, content_segments} do
      {nil, []} -> ""
      {seq, []} -> to_string(seq)
      {nil, segments} -> Enum.join(segments, ",")
      {seq, segments} -> to_string(seq) <> ":" <> Enum.join(segments, ",")
    end
  end

  defp stream_entry_summary(_entry), do: ""

  defp stream_entries(%{pane_state: %{stream_entries: entries}}) when is_list(entries),
    do: entries

  defp stream_entries(_pane), do: []

  defp value_segment(_key, nil), do: nil
  defp value_segment(_key, ""), do: nil
  defp value_segment(key, value), do: key <> "=" <> to_string(value)

  defp media_segment(placeholders) when is_list(placeholders) and placeholders != [] do
    "media=" <> Enum.join(placeholders, ",")
  end

  defp media_segment(_placeholders), do: nil
end
