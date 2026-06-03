defmodule Ourocode.Terminal.ParentChildPaneArea do
  @moduledoc """
  Terminal-native parent/child pane area projection.

  This module is the terminal UI boundary for MCP runtime panes. It consumes
  the dashboard's transport-neutral hierarchy and renders a stable text frame
  with distinct parent and child regions so later TUI implementations can swap
  the renderer without changing session state ownership.
  """

  alias Ourocode.Dashboard.Layout
  alias Ourocode.Dashboard.ScrollbackLedger
  alias Ourocode.Terminal.LayoutSegment

  @terminal_width 80
  @terminal_height 21
  @parent_height 8
  @split_gap 1
  @child_height 12

  @type rendered_area :: %{
          required(:kind) => :parent_child_pane_area,
          required(:layout) => map(),
          required(:parent_region) => map(),
          required(:child_region) => map(),
          required(:roots) => list(map()),
          required(:orphan_children) => list(map())
        }

  @doc """
  Builds a render-ready terminal pane area from parent and child pane states.
  """
  @spec render(map(), map()) :: rendered_area()
  def render(parent_state, child_state) when is_map(parent_state) and is_map(child_state) do
    parent_state
    |> Layout.parent_child_hierarchy(child_state)
    |> render()
  end

  @doc """
  Builds a render-ready terminal pane area from a dashboard runtime hierarchy.
  """
  @spec render(map()) :: rendered_area()
  def render(%{id: :mcp_runtime_hierarchy, roots: roots, orphan_children: orphan_children})
      when is_list(roots) and is_list(orphan_children) do
    parent_region = parent_region()
    child_region = child_region()
    bounds = validate_bounds(parent_region, child_region)

    %{
      kind: :parent_child_pane_area,
      layout: %{
        mode: :terminal_split,
        bounds: bounds,
        regions: %{
          parent: parent_region,
          child: child_region
        }
      },
      parent_region: parent_region,
      child_region: child_region,
      roots: roots,
      orphan_children: orphan_children
    }
  end

  @doc """
  Validates that parent and child terminal regions fit the frame and do not overlap.
  """
  @spec validate_bounds(map(), map()) :: map()
  def validate_bounds(parent_region, child_region)
      when is_map(parent_region) and is_map(child_region) do
    regions = [parent: parent_region, child: child_region]
    terminal_rect = terminal_rect()

    %{
      terminal_width: @terminal_width,
      terminal_height: @terminal_height,
      gap: child_region.y - (parent_region.y + parent_region.height),
      non_overlapping?: not Layout.any_overlaps?([parent_region, child_region]),
      within_terminal?:
        Enum.all?(regions, fn {_name, region} -> Layout.contains_rect?(terminal_rect, region) end),
      positive_dimensions?:
        Enum.all?(regions, fn {_name, region} -> Layout.positive_rect?(region) end)
    }
  end

  @doc """
  Renders the parent/child pane area as terminal-safe text.
  """
  @spec render_text(rendered_area() | map()) :: String.t()
  def render_text(%{kind: :parent_child_pane_area} = area) do
    [
      "+-- Parent/Child Sessions region=runtime_panes layout=terminal_split",
      render_parent_region(area),
      render_child_region(area),
      "+--"
    ]
    |> Enum.join("\n")
  end

  def render_text(%{id: :mcp_runtime_hierarchy} = hierarchy) do
    hierarchy
    |> render()
    |> render_text()
  end

  defp render_parent_region(%{parent_region: region, roots: roots}) do
    header = "| [parent-region] " <> LayoutSegment.rect(region)

    lines =
      case roots do
        [] ->
          ["| parent empty"]

        roots ->
          Enum.map(roots, fn parent ->
            "| parent " <> parent_tree_line(parent)
          end)
      end

    ([header] ++ lines) |> Enum.join("\n")
  end

  defp render_child_region(%{
         child_region: region,
         roots: roots,
         orphan_children: orphan_children
       }) do
    header = "| [child-region] " <> LayoutSegment.rect(region)

    children =
      roots
      |> Enum.flat_map(&Map.get(&1, :children, []))
      |> Kernel.++(orphan_children)

    lines =
      case children do
        [] ->
          ["| child empty"]

        children ->
          Enum.flat_map(children, fn child ->
            ["| child " <> child_tree_line(child)] ++ child_ledger_lines(child)
          end)
      end

    ([header] ++ lines) |> Enum.join("\n")
  end

  defp parent_tree_line(parent) do
    child_count = parent |> Map.get(:children, []) |> length()

    [
      "MCP toolcall " <> parent_tool(parent),
      status_part(parent),
      "#{child_count} child #{plural(child_count, "pane")}",
      event_part(parent)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
    |> Kernel.<>(" · parent=#{parent.parent_call_id}")
  end

  defp child_tree_line(child) do
    [
      child.child_id,
      status_part(child),
      latest_child_output(child),
      "parent=#{child.parent_call_id}"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp parent_tool(parent) do
    get_in(parent, [:params, :name]) ||
      get_in(parent, [:params, "name"]) ||
      Map.get(parent, :method) ||
      "tools/call"
  end

  defp status_part(%{status: status}) when is_binary(status), do: status
  defp status_part(%{status: status}) when is_atom(status), do: Atom.to_string(status)
  defp status_part(_pane), do: "active"

  defp event_part(parent) do
    seq =
      get_in(parent, [:stream_cursor, :event_seq]) ||
        get_in(parent, [:pane_state, :last_event_seq])

    if seq, do: "event #{seq}", else: ""
  end

  defp latest_child_output(%{stream_entries: entries} = child) when is_list(entries) do
    entries
    |> List.last()
    |> stream_entry_text()
    |> case do
      nil -> child_title(child)
      text -> text
    end
  end

  defp latest_child_output(child), do: child_title(child)

  defp child_ledger_lines(%{scrollback_ledger: %{blocks: blocks}})
       when is_list(blocks) and blocks != [] do
    blocks
    |> Enum.take(-5)
    |> Enum.map(fn block ->
      "|   " <> ScrollbackLedger.render_block_line(block)
    end)
  end

  defp child_ledger_lines(_child), do: []

  defp child_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp child_title(_child), do: "stream open"

  defp stream_entry_text(entry) when is_map(entry) do
    Map.get(entry, :token) ||
      Map.get(entry, "token") ||
      Map.get(entry, :delta) ||
      Map.get(entry, "delta") ||
      Map.get(entry, :content) ||
      Map.get(entry, "content")
  end

  defp stream_entry_text(_entry), do: nil

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp parent_region do
    %{x: 0, y: 0, width: @terminal_width, height: @parent_height}
  end

  defp child_region do
    %{x: 0, y: @parent_height + @split_gap, width: @terminal_width, height: @child_height}
  end

  defp terminal_rect, do: %{x: 0, y: 0, width: @terminal_width, height: @terminal_height}
end
