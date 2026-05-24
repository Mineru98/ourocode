defmodule Ourocode.Terminal.RendererOverlay do
  @moduledoc false

  alias Ourocode.Model

  alias Ourocode.Terminal.{
    CommandPaletteDetail,
    KeyHelpRows,
    OverlayWindow,
    Palette,
    Screen
  }

  @left 2
  @overlay_rows 8

  def draw_palette(screen, width, anchor_bottom, %{entries: entries, index: index}) do
    screen =
      draw_overlay(
        screen,
        width,
        anchor_bottom,
        "commands  (#{length(entries)})",
        entries,
        index,
        fn e ->
          tag = if e.availability == :stub, do: "  (stub)", else: ""
          "#{String.pad_trailing(e.slash, 12)} #{e.summary}#{tag}"
        end
      )

    draw_palette_detail(screen, width, anchor_bottom, entries, index)
  end

  def draw_model(screen, width, anchor_bottom, %{models: models, index: index}) do
    draw_overlay(screen, width, anchor_bottom, "model", models, index, fn m ->
      status = if Model.ready?(m), do: "ready", else: "sign in required"
      "#{String.pad_trailing(m.label, 20)} #{status}"
    end)
  end

  def draw_ooo_suggestions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "ooo commands", suggestions, index, fn {command,
                                                                                       summary} ->
      "#{String.pad_trailing(command, 18)} #{summary}"
    end)
  end

  def draw_file_mentions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "@ files", suggestions, index, fn {path, label} ->
      "#{String.pad_trailing("@" <> path, 36)} #{label}"
    end)
  end

  def draw_resource_mentions(screen, width, anchor_bottom, suggestions, index) do
    draw_overlay(screen, width, anchor_bottom, "@ mcp resources", suggestions, index, fn {uri,
                                                                                          label} ->
      "#{String.pad_trailing("@mcp:" <> uri, 40)} #{label}"
    end)
  end

  def draw_key_help(screen, width, anchor_bottom, mode, opts) do
    draw_overlay(screen, width, anchor_bottom, "keys", KeyHelpRows.rows(mode, opts), 0, fn {key,
                                                                                            desc} ->
      "#{String.pad_trailing(key, 18)} #{desc}"
    end)
  end

  defp draw_palette_detail(screen, width, anchor_bottom, entries, index) do
    case Palette.selected(entries, index) do
      nil ->
        screen

      entry ->
        visible_rows = max(min(length(entries), @overlay_rows), 1)
        box_w = width - 2 * @left
        inner = box_w - 2
        rows = CommandPaletteDetail.rows(entry, inner)
        y = anchor_bottom - visible_rows - 2 - length(rows)

        rows
        |> Enum.with_index()
        |> Enum.reduce(screen, fn {row, offset}, acc ->
          Screen.put_text(acc, @left + 1, y + offset, pad(row, inner), :muted)
        end)
    end
  end

  defp draw_overlay(screen, width, anchor_bottom, title, items, index, row_fun) do
    {_offset, windowed} = OverlayWindow.visible(items, index, @overlay_rows)
    box_w = width - 2 * @left
    inner = box_w - 2
    box_h = max(length(windowed), 1) + 2
    y = anchor_bottom - box_h + 1

    screen = Screen.box(screen, @left, y, box_w, box_h, title, :border)

    if windowed == [] do
      Screen.put_text(screen, @left + 1, y + 1, pad("  nothing here", inner), :dim)
    else
      windowed
      |> Enum.with_index()
      |> Enum.reduce(screen, fn {{item, abs_i}, row}, acc ->
        selected? = abs_i == index
        marker = if selected?, do: ">", else: " "
        line = " #{marker} #{row_fun.(item)}"
        style = if selected?, do: :accent, else: :dim
        Screen.put_text(acc, @left + 1, y + 1 + row, pad(line, inner), style)
      end)
    end
  end

  # Pads (or clips) to an exact width so an overlay fully covers whatever it
  # is drawn on top of, leaving no trailing residue.
  defp pad(text, width) do
    t = Screen.truncate(text, width)
    t <> String.duplicate(" ", max(width - Screen.text_width(t), 0))
  end
end
