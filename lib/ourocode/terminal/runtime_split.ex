defmodule Ourocode.Terminal.RuntimeSplit do
  @moduledoc false

  alias Ourocode.Terminal.{FrameSections, RuntimeSplitSidebar, Screen}

  @left 2
  @body 4
  @mcp_right_min 28

  @spec mcp_active?([{String.t(), [String.t()]}]) :: boolean()
  def mcp_active?(sections), do: FrameSections.session_count(sections) > 0

  @spec split_left_width(pos_integer()) :: pos_integer()
  def split_left_width(width), do: max(div(width * 3, 5), 32)

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
    right_x = left_w + 1
    panel_h = max(bottom - right_top + 1, 1)
    inner_x = right_x + 1
    inner_w = max(right_w - 2, 1)
    inner_top = right_top + 1
    region = max(bottom - inner_top + 1, 1)

    body = FrameSections.body(sections, "Parent/Child Sessions")
    parent_lines = RuntimeSplitSidebar.pane_lines(body, "parent ")
    child_lines = RuntimeSplitSidebar.pane_lines(body, "child ")
    reasoning_rows = RuntimeSplitSidebar.wrap_lines(reasoning, inner_w)
    parent_rows = RuntimeSplitSidebar.wrap_lines(parent_lines, inner_w)
    child_rows = RuntimeSplitSidebar.wrap_lines(child_lines, inner_w)
    activity_rows = RuntimeSplitSidebar.wrap_lines(mcp_activity, inner_w)

    activity_h =
      if activity_rows == [],
        do: 0,
        else: min(max(div(region, 3), 5), max(region - 5, 3))

    activity_gap = if activity_h == 0, do: 0, else: 1
    upper_region = max(region - activity_h - activity_gap, 2)

    iv_h =
      if reasoning_rows == [],
        do: 0,
        else: min(length(reasoning_rows), max(div(upper_region, 3), 1)) + 2

    rest = max(upper_region - iv_h, 2)

    {parent_body_h, child_body_h} =
      RuntimeSplitSidebar.section_heights(parent_rows, child_rows, rest)

    parent_top = inner_top + iv_h
    child_top = parent_top + 1 + parent_body_h + 1
    activity_top = inner_top + upper_region + activity_gap
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
    |> Screen.fill_rect(right_x, right_top, right_w, panel_h, :p_fill)
    |> maybe_draw_interview_section(inner_x, inner_top, inner_w, reasoning_rows, iv_h)
    |> RuntimeSplitSidebar.draw_section(
      inner_x,
      parent_top,
      inner_w,
      Map.get(labels, :parent, "Main session (MCP)"),
      parent_rows,
      parent_body_h,
      section_opts
    )
    |> RuntimeSplitSidebar.draw_section(
      inner_x,
      child_top,
      inner_w,
      Map.get(labels, :child, "Delegated session (MCP)"),
      child_rows,
      child_body_h,
      section_opts
    )
    |> maybe_draw_activity_section(
      inner_x,
      activity_top,
      inner_w,
      activity_rows,
      activity_h,
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
