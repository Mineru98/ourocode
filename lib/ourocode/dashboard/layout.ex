defmodule Ourocode.Dashboard.Layout do
  @moduledoc """
  Pure layout projection for compact dashboard panes.

  The layout state is intentionally data-only so pane renderers, hot reload
  strategies, and recovery from the local journal can reason about geometry
  without owning terminal rendering.
  """

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane}

  @compact_session_list_width 36
  @compact_session_list_height 10
  @compact_gap 1
  @compact_task_prompt_width 72
  @compact_task_prompt_height 3
  @layout_lifecycle_types MapSet.new([
                            :dashboard_layout_applied,
                            :dashboard_layout_updated,
                            :layout_applied,
                            :layout_updated
                          ])

  @type rectangle :: %{
          required(:x) => non_neg_integer(),
          required(:y) => non_neg_integer(),
          required(:width) => pos_integer(),
          required(:height) => pos_integer()
        }

  @type pane_layout :: %{
          required(:mode) => :compact,
          required(:region) => :session_lists | :task_prompt,
          required(:order) => pos_integer(),
          required(:rect) => rectangle()
        }

  @doc """
  Attaches compact layout rectangles to the Working and Completed panes.

  The two session-list panes are stacked in a shared compact session-list
  region with a fixed gap, which keeps them visibly grouped while preserving a
  non-overlapping geometry contract for terminal renderers.
  """
  @spec apply_compact_session_list_layout(map()) :: map()
  def apply_compact_session_list_layout(%{working: working, completed: completed} = panes) do
    working_layout = session_list_layout(1, 0)

    completed_layout =
      session_list_layout(2, @compact_session_list_height + @compact_gap)

    panes
    |> Map.put(:working, Map.put(working, :layout, working_layout))
    |> Map.put(:completed, Map.put(completed, :layout, completed_layout))
    |> maybe_put_task_prompt_layout()
    |> Map.put(:layout, %{
      mode: :compact,
      regions:
        %{
          session_lists: %{
            x: 0,
            y: 0,
            width: @compact_session_list_width,
            height: @compact_session_list_height * 2 + @compact_gap,
            panes: [:working_sessions, :completed_sessions]
          }
        }
        |> maybe_put_task_prompt_region(panes)
    })
  end

  @doc """
  Replays persisted dashboard layout journal records into pane layout metadata.

  Runtime panes are recovered separately from parent/child lifecycle events.
  Layout journal records only restore the dashboard-local geometry and view
  metadata that renderers need after restart.
  """
  @spec recover_from_journal([map()]) :: map()
  @spec recover_from_journal([map()], map()) :: map()
  def recover_from_journal(events, initial_state \\ %{})

  def recover_from_journal(events, initial_state)
      when is_list(events) and is_map(initial_state) do
    Enum.reduce(events, initial_state, &apply_event(&2, &1))
  end

  @doc """
  Applies one persisted layout journal record to dashboard layout state.
  """
  @spec apply_event(map(), map()) :: map()
  def apply_event(state, event) when is_map(state) and is_map(event) do
    case layout_lifecycle_type(event) do
      {:ok, _type} ->
        state
        |> put_root_layout(event)
        |> put_pane_layouts(event)
        |> put_view_metadata(event)

      :ignore ->
        state
    end
  end

  @doc """
  Returns true when two rectangle maps intersect.
  """
  @spec overlaps?(rectangle(), rectangle()) :: boolean()
  def overlaps?(left, right) do
    left.x < right.x + right.width and
      right.x < left.x + left.width and
      left.y < right.y + right.height and
      right.y < left.y + left.height
  end

  @doc """
  Builds the runtime UI hierarchy from parent MCP panes and child session panes.

  Parent panes are always roots. Child panes are nested only under the parent
  whose `parent_call_id` matches the child pane mapping; unmatched children are
  returned as orphans so renderers can avoid leaking them into sibling roots.
  """
  @spec parent_child_hierarchy(map(), map()) :: map()
  def parent_child_hierarchy(parent_state, child_state)
      when is_map(parent_state) and is_map(child_state) do
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

  @doc """
  Renders one compact MCP runtime frame containing parent panes and all sibling
  child/session panes that belong to each parent.

  This is a pure frame projection for terminal renderers and tests. It keeps
  sibling child panes in the same frame instead of replacing the previously
  rendered child for a parent.
  """
  @spec render_runtime_frame(map(), map()) :: String.t()
  def render_runtime_frame(parent_state, child_state)
      when is_map(parent_state) and is_map(child_state) do
    parent_state
    |> parent_child_hierarchy(child_state)
    |> render_runtime_frame()
  end

  @spec render_runtime_frame(map()) :: String.t()
  def render_runtime_frame(%{id: :mcp_runtime_hierarchy, roots: roots, orphan_children: orphans})
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

  defp maybe_put_task_prompt_region(regions, %{task_prompt: _task_prompt}) do
    Map.put(regions, :task_prompt, %{
      x: 0,
      y: @compact_session_list_height * 2 + @compact_gap + @compact_gap,
      width: @compact_task_prompt_width,
      height: @compact_task_prompt_height,
      panes: [:task_prompt]
    })
  end

  defp maybe_put_task_prompt_region(regions, _panes), do: regions

  defp session_list_layout(order, y) do
    %{
      mode: :compact,
      region: :session_lists,
      order: order,
      rect: %{
        x: 0,
        y: y,
        width: @compact_session_list_width,
        height: @compact_session_list_height
      }
    }
  end

  defp maybe_put_task_prompt_layout(%{task_prompt: task_prompt} = panes) do
    Map.put(panes, :task_prompt, Map.put(task_prompt, :layout, task_prompt_layout()))
  end

  defp maybe_put_task_prompt_layout(panes), do: panes

  defp task_prompt_layout do
    %{
      mode: :compact,
      region: :task_prompt,
      order: 1,
      rect: %{
        x: 0,
        y: @compact_session_list_height * 2 + @compact_gap + @compact_gap,
        width: @compact_task_prompt_width,
        height: @compact_task_prompt_height
      }
    }
  end

  defp layout_lifecycle_type(event) do
    case metadata_value(event, :type) do
      type when is_atom(type) ->
        if MapSet.member?(@layout_lifecycle_types, type), do: {:ok, type}, else: :ignore

      type when is_binary(type) ->
        type = string_to_existing_layout_type(type)

        if is_atom(type) and MapSet.member?(@layout_lifecycle_types, type) do
          {:ok, type}
        else
          :ignore
        end

      _type ->
        :ignore
    end
  end

  defp string_to_existing_layout_type("dashboard_layout_applied"), do: :dashboard_layout_applied
  defp string_to_existing_layout_type("dashboard_layout_updated"), do: :dashboard_layout_updated
  defp string_to_existing_layout_type("layout_applied"), do: :layout_applied
  defp string_to_existing_layout_type("layout_updated"), do: :layout_updated
  defp string_to_existing_layout_type(type), do: type

  defp put_root_layout(state, event) do
    case metadata_map(event, :layout, nil) do
      layout when is_map(layout) -> Map.put(state, :layout, normalize_layout_map(layout))
      _layout -> state
    end
  end

  defp put_pane_layouts(state, event) do
    event
    |> metadata_map(:pane_layouts, %{})
    |> Enum.reduce(state, fn {pane_key, layout}, acc ->
      pane_key = pane_layout_key(pane_key)

      if is_atom(pane_key) and is_map(layout) do
        Map.update(acc, pane_key, %{layout: normalize_layout_map(layout)}, fn
          pane when is_map(pane) -> Map.put(pane, :layout, normalize_layout_map(layout))
          pane -> pane
        end)
      else
        acc
      end
    end)
  end

  defp put_view_metadata(state, event) do
    state
    |> maybe_put_view_value(:focused, metadata_value(event, :focused))
    |> maybe_put_view_value(:open, metadata_value(event, :open))
  end

  defp maybe_put_view_value(state, _key, nil), do: state

  defp maybe_put_view_value(state, :focused, focused) when is_binary(focused) do
    Map.put(state, :focused, layout_atom(focused))
  end

  defp maybe_put_view_value(state, :focused, focused) when is_atom(focused) do
    Map.put(state, :focused, focused)
  end

  defp maybe_put_view_value(state, :open, open) when is_list(open) do
    Map.put(state, :open, Enum.map(open, &layout_atom/1))
  end

  defp maybe_put_view_value(state, _key, _value), do: state

  defp pane_layout_key(key) when key in [:working, :completed, :task_prompt], do: key
  defp pane_layout_key("working"), do: :working
  defp pane_layout_key("completed"), do: :completed
  defp pane_layout_key("task_prompt"), do: :task_prompt
  defp pane_layout_key("working_sessions"), do: :working
  defp pane_layout_key("completed_sessions"), do: :completed
  defp pane_layout_key(key), do: key

  defp normalize_layout_map(layout) when is_map(layout) do
    Map.new(layout, fn {key, value} ->
      normalized_key = layout_key(key)
      {normalized_key, normalize_layout_value(normalized_key, value)}
    end)
  end

  defp normalize_layout_value(key, value) when key in [:mode, :region], do: layout_atom(value)

  defp normalize_layout_value(:panes, value) when is_list(value),
    do: Enum.map(value, &layout_atom/1)

  defp normalize_layout_value(:rect, value) when is_map(value), do: normalize_rect(value)
  defp normalize_layout_value(:regions, value) when is_map(value), do: normalize_regions(value)
  defp normalize_layout_value(_key, value), do: value

  defp normalize_regions(regions) do
    Map.new(regions, fn {key, value} ->
      {layout_atom(key), normalize_layout_map(value)}
    end)
  end

  defp normalize_rect(rect) do
    Map.new(rect, fn {key, value} -> {layout_key(key), value} end)
  end

  defp layout_key("mode"), do: :mode
  defp layout_key("region"), do: :region
  defp layout_key("order"), do: :order
  defp layout_key("rect"), do: :rect
  defp layout_key("x"), do: :x
  defp layout_key("y"), do: :y
  defp layout_key("width"), do: :width
  defp layout_key("height"), do: :height
  defp layout_key("regions"), do: :regions
  defp layout_key("panes"), do: :panes
  defp layout_key(key), do: key

  defp layout_atom(value) when is_atom(value), do: value
  defp layout_atom("compact"), do: :compact
  defp layout_atom("session_lists"), do: :session_lists
  defp layout_atom("task_prompt"), do: :task_prompt
  defp layout_atom("working_sessions"), do: :working_sessions
  defp layout_atom("completed_sessions"), do: :completed_sessions
  defp layout_atom(value), do: value

  defp metadata_map(metadata, key, default) do
    case metadata_value(metadata, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, to_string(key))
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
      stream_event_count: rendered.stream_event_count,
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
      stream_segment(child)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp title_segment(%{title: title}) when is_binary(title) and title != "" do
    "title=" <> inspect(title)
  end

  defp title_segment(_child), do: nil

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
