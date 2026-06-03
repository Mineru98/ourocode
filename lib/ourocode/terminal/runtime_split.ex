defmodule Ourocode.Terminal.RuntimeSplit do
  @moduledoc false

  alias Ourocode.Terminal.{FrameSections, RuntimeSplitSidebar, Screen, WorkflowRail}

  @left 2
  @body 4
  @mcp_right_min 34

  @spec mcp_active?([{String.t(), [String.t()]}]) :: boolean()
  def mcp_active?(sections), do: FrameSections.session_count(sections) > 0

  @spec split_left_width(pos_integer()) :: pos_integer()
  def split_left_width(width) do
    desired = max(div(width * 2, 3), 40)
    max_left_with_sidebar = max(width - @mcp_right_min - 1, 32)

    min(desired, max_left_with_sidebar)
  end

  @spec draw(
          map(),
          pos_integer(),
          integer(),
          integer(),
          integer(),
          [String.t()],
          [{String.t(), [String.t()]}],
          non_neg_integer(),
          [String.t()],
          [String.t()],
          function(),
          map()
        ) :: map()
  def draw(
        screen,
        width,
        left_top,
        right_top,
        bottom,
        activity,
        sections,
        scroll,
        reasoning,
        mcp_activity,
        draw_transcript,
        opts \\ %{}
      )
      when is_function(draw_transcript, 8) do
    left_w = split_left_width(width)
    right_w = width - left_w - 1

    if right_w < @mcp_right_min do
      draw_transcript.(screen, width, left_top, bottom, activity, true, scroll, nil)
    else
      draw_two_column(
        screen,
        left_w,
        right_w,
        left_top,
        right_top,
        bottom,
        activity,
        sections,
        scroll,
        reasoning,
        mcp_activity,
        draw_transcript,
        opts
      )
    end
  end

  @doc false
  def scroll_tail(lines, body_h, scroll) do
    RuntimeSplitSidebar.scroll_tail(lines, body_h, scroll)
  end

  @doc false
  def section_heights(parent_lines, child_lines, region) do
    RuntimeSplitSidebar.section_heights(parent_lines, child_lines, region)
  end

  @doc false
  def pane_lines(body, prefix) do
    RuntimeSplitSidebar.pane_lines(body, prefix)
  end

  @doc false
  def layout_metrics(width, right_top, bottom, sections, reasoning, mcp_activity, opts \\ %{}) do
    left_w = split_left_width(width)
    right_w = width - left_w - 1
    right_x = left_w + 1
    inner_x = right_x + 1
    inner_w = max(right_w - 2, 1)
    inner_top = right_top + 1
    region = max(bottom - inner_top + 1, 1)

    body = FrameSections.body(sections, "Parent/Child Sessions")
    parent_lines = Map.get(opts, :parent_lines) || RuntimeSplitSidebar.pane_lines(body, "parent ")
    child_lines = Map.get(opts, :child_lines) || RuntimeSplitSidebar.pane_lines(body, "child ")

    workflow_rows =
      WorkflowRail.rows(sections, reasoning, mcp_activity, Map.get(opts, :workflow, %{}))

    reasoning_rows = RuntimeSplitSidebar.wrap_lines(reasoning, inner_w)
    parent_rows = RuntimeSplitSidebar.wrap_lines(parent_lines, inner_w)
    child_rows = RuntimeSplitSidebar.wrap_lines(child_lines, inner_w)
    activity_rows = RuntimeSplitSidebar.wrap_lines(mcp_activity, inner_w)

    activity_h =
      if activity_rows == [],
        do: 0,
        else: min(max(div(region, 3), 5), max(region - 5, 3))

    activity_gap = if activity_h == 0, do: 0, else: 1
    workflow_h = min(length(workflow_rows), max(div(region, 5), 3)) + 1
    workflow_gap = 1
    upper_region = max(region - workflow_h - workflow_gap - activity_h - activity_gap, 2)

    iv_h =
      if reasoning_rows == [],
        do: 0,
        else: min(length(reasoning_rows), max(div(upper_region, 3), 1)) + 2

    rest = max(upper_region - iv_h, 2)

    {parent_body_h, child_body_h} =
      RuntimeSplitSidebar.section_heights(parent_rows, child_rows, rest)

    %{
      left_w: left_w,
      right_w: right_w,
      right_x: right_x,
      inner_x: inner_x,
      inner_w: inner_w,
      inner_top: inner_top,
      panel_h: max(bottom - right_top + 1, 1),
      workflow_rows: workflow_rows,
      reasoning_rows: reasoning_rows,
      parent_rows: parent_rows,
      child_rows: child_rows,
      activity_rows: activity_rows,
      workflow_h: workflow_h,
      workflow_gap: workflow_gap,
      iv_h: iv_h,
      parent_top: inner_top + workflow_h + workflow_gap + iv_h,
      child_top: inner_top + workflow_h + workflow_gap + iv_h + 1 + parent_body_h + 1,
      activity_top: inner_top + workflow_h + workflow_gap + upper_region + activity_gap,
      parent_body_h: parent_body_h,
      child_body_h: child_body_h,
      activity_h: activity_h
    }
  end

  defp draw_two_column(
         screen,
         left_w,
         right_w,
         left_top,
         right_top,
         bottom,
         activity,
         sections,
         scroll,
         reasoning,
         mcp_activity,
         draw_transcript,
         opts
       ) do
    metrics =
      layout_metrics(
        left_w + right_w + 1,
        right_top,
        bottom,
        sections,
        reasoning,
        mcp_activity,
        opts
      )

    workflow_top = metrics.inner_top
    transcript_clip_w = max(left_w - @body - @left, 1)
    labels = Map.get(opts, :labels, %{})
    section_opts = Map.get(opts, :section_opts, %{})
    activity_opts = Map.get(opts, :activity_opts, %{})

    screen
    |> draw_transcript.(
      left_w,
      left_top,
      bottom,
      activity,
      true,
      scroll,
      transcript_clip_w
    )
    |> Screen.fill_rect(metrics.right_x, right_top, metrics.right_w, metrics.panel_h, :p_fill)
    |> RuntimeSplitSidebar.draw_section(
      metrics.inner_x,
      workflow_top,
      metrics.inner_w,
      Map.get(labels, :workflow, "workflow rail"),
      metrics.workflow_rows,
      max(metrics.workflow_h - 1, 1),
      Map.merge(section_opts, %{status: "method"})
    )
    |> maybe_draw_interview_section(
      metrics.inner_x,
      metrics.inner_top + metrics.workflow_h + metrics.workflow_gap,
      metrics.inner_w,
      metrics.reasoning_rows,
      metrics.iv_h
    )
    |> RuntimeSplitSidebar.draw_section(
      metrics.inner_x,
      metrics.parent_top,
      metrics.inner_w,
      Map.get(labels, :parent, "MCP graph"),
      metrics.parent_rows,
      metrics.parent_body_h,
      section_opts
    )
    |> RuntimeSplitSidebar.draw_section(
      metrics.inner_x,
      metrics.child_top,
      metrics.inner_w,
      Map.get(labels, :child, "pane ledgers"),
      metrics.child_rows,
      metrics.child_body_h,
      section_opts
    )
    |> maybe_draw_activity_section(
      metrics.inner_x,
      metrics.activity_top,
      metrics.inner_w,
      metrics.activity_rows,
      metrics.activity_h,
      scroll,
      labels,
      activity_opts
    )
  end

  defp maybe_draw_interview_section(screen, _x, _y, _w, [], _h), do: screen

  defp maybe_draw_interview_section(screen, x, y, w, reasoning, iv_h) do
    RuntimeSplitSidebar.draw_section(screen, x, y, w, "interview", reasoning, max(iv_h - 2, 1))
  end

  defp maybe_draw_activity_section(screen, _x, _y, _w, [], _h, _scroll, _labels, _opts),
    do: screen

  defp maybe_draw_activity_section(screen, _x, _y, _w, _lines, h, _scroll, _labels, _opts)
       when h < 2,
       do: screen

  defp maybe_draw_activity_section(screen, x, y, w, lines, h, scroll, labels, opts) do
    RuntimeSplitSidebar.draw_activity(
      screen,
      x,
      y,
      w,
      Map.get(labels, :activity, "activity log"),
      lines,
      h - 1,
      scroll,
      opts
    )
  end
end
