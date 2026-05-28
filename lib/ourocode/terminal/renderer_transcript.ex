defmodule Ourocode.Terminal.RendererTranscript do
  @moduledoc false

  alias Ourocode.Terminal.{Screen, TextWrap, TranscriptRows}

  @left 2
  @body 4

  # Turns render as scannable blocks: a dim role label, a coloured left rail,
  # and an indented body instead of a flat log.
  @spec draw(
          Screen.t(),
          pos_integer(),
          integer(),
          integer(),
          [String.t()] | nil,
          boolean(),
          non_neg_integer(),
          integer() | nil
        ) :: Screen.t()
  def draw(
        screen,
        width,
        top,
        bottom,
        activity,
        show_empty_hint,
        scroll,
        clip_override \\ nil
      )

  def draw(screen, _width, top, bottom, _activity, _show_empty_hint, _scroll, _clip_override)
      when top > bottom,
      do: screen

  def draw(screen, width, top, bottom, activity, show_empty_hint, scroll, clip_override) do
    region = max(bottom - top + 1, 1)
    render_rows = TranscriptRows.rows(activity)
    workspace? = TranscriptRows.workspace_activity?(activity)
    clip_w = clip_override || width - @body - @left
    render_rows = if workspace?, do: wrap_workspace_rows(render_rows, clip_w), else: render_rows

    cond do
      render_rows == [] and not show_empty_hint ->
        screen

      render_rows == [] ->
        draw_empty_state(screen, width, top, region)

      true ->
        render_activity_rows(
          screen,
          width,
          top,
          bottom,
          region,
          render_rows,
          scroll,
          clip_w,
          workspace?
        )
    end
  end

  defp render_activity_rows(
         screen,
         _width,
         top,
         bottom,
         region,
         render_rows,
         scroll,
         clip_w,
         workspace?
       ) do
    total = length(render_rows)
    max_offset = max(total - region, 0)
    offset = min(max(scroll, 0), max_offset)

    {visible, start} =
      if workspace? do
        visible = Enum.slice(render_rows, offset, region)
        {visible, top}
      else
        slice_end = total - offset
        slice_start = max(slice_end - region, 0)
        visible = Enum.slice(render_rows, slice_start, slice_end - slice_start)
        {visible, bottom - length(visible) + 1}
      end

    visible
    |> Enum.with_index()
    |> Enum.reduce(screen, fn {row, i}, acc ->
      y = start + i

      acc =
        case row.rail do
          nil -> acc
          ch -> Screen.put_text(acc, @left, y, ch, row.rail_style)
        end

      Screen.put_text(acc, @body, y, clip(row.text, clip_w), row.text_style)
    end)
  end

  defp clip(text, max_width), do: Screen.truncate(text, max_width)

  defp wrap_workspace_rows(rows, clip_w) do
    Enum.flat_map(rows, fn row ->
      text = Map.get(row, :text, "")

      if Screen.text_width(text) <= clip_w do
        [row]
      else
        continuation = "  "
        wrap_width = max(clip_w - Screen.text_width(continuation), 1)

        text
        |> TextWrap.wrap(wrap_width)
        |> Enum.with_index()
        |> Enum.map(fn
          {segment, 0} ->
            %{row | text: segment}

          {segment, _index} ->
            %{row | rail: continuation_rail(row), text: continuation <> segment}
        end)
      end
    end)
  end

  defp continuation_rail(%{rail: rail}) when is_binary(rail), do: rail
  defp continuation_rail(_row), do: nil

  defp draw_empty_state(screen, width, top, region) do
    rows = empty_state_rows(width)
    visible = Enum.take(rows, region)
    start = top + max(div(region - length(visible), 2), 0)

    visible
    |> Enum.with_index()
    |> Enum.reduce(screen, fn {{text, style, align}, offset}, acc ->
      y = start + offset

      case align do
        :center -> center(acc, y, width, text, style)
        :left -> put_empty_text(acc, y, width, text, style)
      end
    end)
  end

  defp empty_state_rows(width) when width < 72 do
    [
      {"ourocode", :brand, :center},
      {"Choose a start mode.", :dim, :center},
      {"● pm  · product requirements", :accent, :center},
      {"interview · clarify decisions", :muted, :center},
      {"auto · plan then execute", :muted, :center},
      {"/ for commands", :muted, :center}
    ]
  end

  defp empty_state_rows(_width) do
    [
      {"ourocode", :brand, :center},
      {"Choose one starting mode, then add the goal.", :dim, :center},
      {"● ooo pm <goal>         product requirements with answer choices", :accent, :center},
      {"  ooo interview <goal>  clarify decisions through questions", :muted, :center},
      {"  ooo auto <goal>       plan, verify, then execute", :muted, :center},
      {"/ for commands", :muted, :center}
    ]
  end

  defp put_empty_text(screen, y, width, text, style) do
    x = max(div(width - 64, 2), @body)
    Screen.put_text(screen, x, y, clip(text, width - x - @left), style)
  end

  defp center(screen, y, width, text, style) do
    x = max(div(width - Screen.text_width(text), 2), 0)
    Screen.put_text(screen, x, y, text, style)
  end
end
