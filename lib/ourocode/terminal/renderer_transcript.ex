defmodule Ourocode.Terminal.RendererTranscript do
  @moduledoc false

  alias Ourocode.Terminal.{Screen, TranscriptRows}

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

    cond do
      render_rows == [] and not show_empty_hint ->
        screen

      render_rows == [] ->
        mid = top + div(region, 2)

        screen
        |> center(mid - 1, width, "ourocode", :brand)
        |> center(mid + 1, width, "Sign in with  /login,  then ask anything", :dim)
        |> center(mid + 2, width, "or type  /  to browse commands", :muted)

      true ->
        render_activity_rows(screen, width, bottom, region, render_rows, scroll, clip_override)
    end
  end

  defp render_activity_rows(screen, width, bottom, region, render_rows, scroll, clip_override) do
    total = length(render_rows)
    offset = min(max(scroll, 0), max(total - region, 0))
    slice_end = total - offset
    slice_start = max(slice_end - region, 0)
    visible = Enum.slice(render_rows, slice_start, slice_end - slice_start)
    start = bottom - length(visible) + 1

    visible
    |> Enum.with_index()
    |> Enum.reduce(screen, fn {row, i}, acc ->
      y = start + i

      acc =
        case row.rail do
          nil -> acc
          ch -> Screen.put_text(acc, @left, y, ch, row.rail_style)
        end

      clip_w = clip_override || width - @body - @left
      Screen.put_text(acc, @body, y, clip(row.text, clip_w), row.text_style)
    end)
  end

  defp clip(text, max_width), do: Screen.truncate(text, max_width)

  defp center(screen, y, width, text, style) do
    x = max(div(width - Screen.text_width(text), 2), 0)
    Screen.put_text(screen, x, y, text, style)
  end
end
