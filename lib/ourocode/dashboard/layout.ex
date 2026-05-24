defmodule Ourocode.Dashboard.Layout do
  @moduledoc """
  Pure layout projection for compact dashboard panes.

  The layout state is intentionally data-only so pane renderers, hot reload
  strategies, and recovery from the local journal can reason about geometry
  without owning terminal rendering.
  """

  alias Ourocode.Dashboard.LayoutRecovery
  alias Ourocode.Dashboard.LayoutRuntimeHierarchy

  @compact_session_list_width 36
  @compact_session_list_height 10
  @compact_gap 1
  @compact_task_prompt_width 72
  @compact_task_prompt_height 3
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
    LayoutRecovery.recover_from_journal(events, initial_state)
  end

  @doc """
  Applies one persisted layout journal record to dashboard layout state.
  """
  @spec apply_event(map(), map()) :: map()
  def apply_event(state, event) when is_map(state) and is_map(event) do
    LayoutRecovery.apply_event(state, event)
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
  Returns true when a rectangle has positive width and height.
  """
  @spec positive_rect?(map()) :: boolean()
  def positive_rect?(%{width: width, height: height})
      when is_integer(width) and is_integer(height) and width > 0 and height > 0,
      do: true

  def positive_rect?(_rect), do: false

  @doc """
  Returns true when a rectangle is fully contained by another rectangle.
  """
  @spec contains_rect?(rectangle(), rectangle()) :: boolean()
  def contains_rect?(container, rect) do
    positive_rect?(container) and positive_rect?(rect) and
      is_integer(container.x) and is_integer(container.y) and is_integer(rect.x) and
      is_integer(rect.y) and rect.x >= container.x and rect.y >= container.y and
      rect.x + rect.width <= container.x + container.width and
      rect.y + rect.height <= container.y + container.height
  end

  @doc """
  Returns true when any rectangle in a list intersects another rectangle.
  """
  @spec any_overlaps?([rectangle()]) :: boolean()
  def any_overlaps?(rects) when is_list(rects) do
    rects
    |> rectangle_pairs()
    |> Enum.any?(fn {left, right} -> overlaps?(left, right) end)
  end

  @doc """
  Returns the smallest rectangle that contains all supplied rectangles.
  """
  @spec bounding_rect([rectangle(), ...]) :: rectangle()
  def bounding_rect([_rect | _rest] = rects) do
    min_x = rects |> Enum.map(& &1.x) |> Enum.min()
    min_y = rects |> Enum.map(& &1.y) |> Enum.min()
    max_x = rects |> Enum.map(&(&1.x + &1.width)) |> Enum.max()
    max_y = rects |> Enum.map(&(&1.y + &1.height)) |> Enum.max()

    %{x: min_x, y: min_y, width: max_x - min_x, height: max_y - min_y}
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
    LayoutRuntimeHierarchy.build(parent_state, child_state)
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
    LayoutRuntimeHierarchy.render_frame(%{
      id: :mcp_runtime_hierarchy,
      roots: roots,
      orphan_children: orphans
    })
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

  defp rectangle_pairs([]), do: []
  defp rectangle_pairs([_rect]), do: []
  defp rectangle_pairs([rect | rest]), do: Enum.map(rest, &{rect, &1}) ++ rectangle_pairs(rest)

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
end
