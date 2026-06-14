defmodule Ourocode.Terminal.RendererOverlay do
  @moduledoc false

  alias Ourocode.Model
  alias Ourocode.Model.Profile

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
    slash_w = palette_slash_width(entries)

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
          "#{String.pad_trailing(e.slash, slash_w)} #{e.summary}#{tag}"
        end
      )

    draw_palette_detail(screen, width, anchor_bottom, entries, index)
  end

  def draw_model(screen, width, anchor_bottom, %{models: models, index: index}) do
    draw_model_overlay(screen, width, anchor_bottom, models, index)
  end

  def draw_ooo_suggestions(screen, width, anchor_bottom, suggestions, index) do
    draw_workflow_overlay(screen, width, anchor_bottom, suggestions, index)
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
          Screen.put_text(acc, @left + 1, y + offset, pad(row, inner), :p_muted)
        end)
    end
  end

  defp ooo_example("ooo interview"), do: "ooo interview \"clarify the release UX\""
  defp ooo_example("ooo auto"), do: "ooo auto \"ship the smallest safe improvement\""
  defp ooo_example("ooo run"), do: "ooo run seed.yaml"
  defp ooo_example("ooo seed"), do: "ooo seed <session_id>"
  defp ooo_example(command), do: command <> " <context>"

  defp palette_slash_width(entries) do
    entries
    |> Enum.map(&Screen.text_width(Map.get(&1, :slash, "")))
    |> Enum.max(fn -> 12 end)
    |> max(12)
    |> min(18)
  end

  defp draw_overlay(screen, width, anchor_bottom, title, items, index, row_fun) do
    {_offset, windowed} = OverlayWindow.visible(items, index, @overlay_rows)
    box_w = width - 2 * @left
    inner = box_w - 2
    box_h = max(length(windowed), 1) + 2
    y = anchor_bottom - box_h + 1

    screen = draw_panel(screen, y, box_w, box_h, title)

    if windowed == [] do
      Screen.put_text(screen, @left + 1, y + 1, pad("  nothing here", inner), :p_muted)
    else
      windowed
      |> Enum.with_index()
      |> Enum.reduce(screen, fn {{item, abs_i}, row}, acc ->
        selected? = abs_i == index
        marker = if selected?, do: "● >", else: "  "
        line = " #{marker} #{row_fun.(item)}"
        style = if selected?, do: :p_accent, else: :p_dim
        Screen.put_text(acc, @left + 1, y + 1 + row, pad(line, inner), style)
      end)
    end
  end

  defp draw_workflow_overlay(screen, width, anchor_bottom, suggestions, index) do
    {_offset, windowed} = OverlayWindow.visible(suggestions, index, @overlay_rows)
    box_w = width - 2 * @left
    inner = box_w - 2
    detail_rows = workflow_detail_rows(Enum.at(suggestions, index), inner)
    gap_rows = 1
    box_h = length(detail_rows) + gap_rows + @overlay_rows + 2
    y = max(anchor_bottom - box_h + 1, 0)

    screen = draw_panel(screen, y, box_w, box_h, workflow_title(inner))

    screen =
      detail_rows
      |> Enum.with_index()
      |> Enum.reduce(screen, fn {row, offset}, acc ->
        style = if offset == 0, do: :p_accent, else: :p_dim
        Screen.put_text(acc, @left + 1, y + 1 + offset, pad(row, inner), style)
      end)

    list_y = y + 1 + length(detail_rows) + gap_rows

    rows =
      if windowed == [] do
        [{:empty, nil}]
      else
        Enum.map(windowed, fn {item, abs_i} -> {:item, {item, abs_i}} end)
      end

    rows
    |> pad_rows(@overlay_rows)
    |> Enum.with_index()
    |> Enum.reduce(screen, fn
      {{:empty, _none}, row}, acc ->
        Screen.put_text(acc, @left + 1, list_y + row, pad("  nothing here", inner), :p_muted)

      {{:blank, _none}, row}, acc ->
        Screen.put_text(acc, @left + 1, list_y + row, pad("", inner), :p_dim)

      {{:item, {{command, summary}, abs_i}}, row}, acc ->
        selected? = abs_i == index
        marker = if selected?, do: "● >", else: "  "
        command_w = workflow_command_width(inner)

        line =
          " #{marker} #{String.pad_trailing(command, command_w)} #{workflow_summary(summary, inner)}"

        style = if selected?, do: :p_accent, else: :p_dim
        Screen.put_text(acc, @left + 1, list_y + row, pad(line, inner), style)
    end)
  end

  defp draw_model_overlay(screen, width, anchor_bottom, models, index) do
    box_w = width - 2 * @left
    inner = box_w - 2
    detail_rows = model_profile_rows(models, inner)
    gap_rows = 1
    list_rows = max(min(@overlay_rows, anchor_bottom - length(detail_rows) - gap_rows - 1), 1)
    {_offset, windowed} = OverlayWindow.visible(models, index, list_rows)
    box_h = length(detail_rows) + gap_rows + list_rows + 2
    y = max(anchor_bottom - box_h + 1, 0)

    screen = draw_panel(screen, y, box_w, box_h, model_title(inner))

    screen =
      detail_rows
      |> Enum.with_index()
      |> Enum.reduce(screen, fn {row, offset}, acc ->
        style = if offset == 0, do: :p_accent, else: :p_dim
        Screen.put_text(acc, @left + 1, y + 1 + offset, pad(row, inner), style)
      end)

    list_y = y + 1 + length(detail_rows) + gap_rows

    model_rows =
      if windowed == [] do
        [{:empty, nil}]
      else
        Enum.map(windowed, fn {item, abs_i} -> {:item, {item, abs_i}} end)
      end

    model_rows
    |> pad_rows(list_rows)
    |> Enum.with_index()
    |> Enum.reduce(screen, fn
      {{:empty, _none}, row}, acc ->
        Screen.put_text(
          acc,
          @left + 1,
          list_y + row,
          pad("  no selectable backends", inner),
          :p_muted
        )

      {{:blank, _none}, row}, acc ->
        Screen.put_text(acc, @left + 1, list_y + row, pad("", inner), :p_dim)

      {{:item, {model, abs_i}}, row}, acc ->
        selected? = abs_i == index
        marker = if selected?, do: "● >", else: "  "
        line = " #{marker} #{model_row(model, inner)}"
        style = if selected?, do: :p_accent, else: :p_dim
        Screen.put_text(acc, @left + 1, list_y + row, pad(line, inner), style)
    end)
  end

  defp model_title(inner) when inner < 58, do: "models + roles"
  defp model_title(_inner), do: "models · Ouroboros role profiles"

  defp model_profile_rows(models, inner) do
    rows =
      if inner < 58 do
        [
          "Ouroboros picks by role",
          "Socratic   " <> profile_model(:interview, models),
          "Execute    " <> profile_model(:evolve, models),
          "Verify     " <> profile_model(:qa, models)
        ]
      else
        [
          "Ouroboros profiles choose the runtime for each workflow stage",
          "Socratic Interview  " <> profile_model(:interview, models),
          "Execute/Evolve  " <> profile_model(:evolve, models),
          "Verify/QA       " <> profile_model(:qa, models)
        ]
      end

    Enum.map(rows, &Screen.truncate(&1, inner))
  end

  defp profile_model(route, models) do
    route
    |> Profile.for_route(models: models)
    |> Map.fetch!(:model_label)
    |> Profile.short_model_label()
  end

  defp model_row(%Model{} = model, inner) do
    status = if Model.ready?(model), do: "ready", else: auth_status(model)
    role_hint = model_role_hint(model)

    label_width = if inner < 58, do: 16, else: 24
    status_width = if inner < 58, do: 10, else: 14

    [
      String.pad_trailing(Profile.short_model_label(model.label), label_width),
      String.pad_trailing(status, status_width),
      role_hint
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp auth_status(%Model{status: {:needs_auth, hint}}), do: "sign in " <> hint
  defp auth_status(_model), do: "unavailable"

  defp model_role_hint(%Model{id: :claude_api}), do: "socratic/verify"

  defp model_role_hint(%Model{id: :codex}), do: "execute/evolve"

  defp model_role_hint(%Model{id: :gemini}), do: "fallback"
  defp model_role_hint(_model), do: ""

  defp workflow_title(inner) when inner < 58, do: "ooo workflows"
  defp workflow_title(_inner), do: "ooo structured work"

  defp workflow_command_width(inner) when inner < 58, do: 12
  defp workflow_command_width(_inner), do: 18

  defp workflow_summary(summary, inner) when inner < 58 do
    cond do
      String.contains?(summary, "PM interview") -> "PM interview"
      String.contains?(summary, "Socratic") -> "clarify requirements"
      String.contains?(summary, "draft a plan") -> "plan then execute"
      String.contains?(summary, "vague requirements") -> "make requirements concrete"
      String.contains?(summary, "reusable task") -> "create task plan"
      true -> summary
    end
  end

  defp workflow_summary(summary, _inner), do: summary

  defp workflow_detail_rows(nil, inner) do
    rows =
      if inner < 58 do
        ["Pick an ooo command", "Enter inserts it; add context"]
      else
        ["Pick a guided-work command", "Enter inserts the command. Add context, then run."]
      end

    rows
    |> Enum.map(&Screen.truncate(&1, inner))
  end

  defp workflow_detail_rows({command, summary}, inner) do
    rows =
      if inner < 58 do
        [
          "● #{command} · #{workflow_summary(summary, inner)}",
          "Enter inserts it; add context",
          "Try · #{ooo_example(command)}"
        ]
      else
        [
          "● #{command} · #{summary}",
          "Enter inserts command; add context before running",
          "Try · #{ooo_example(command)}"
        ]
      end

    rows
    |> Enum.map(&Screen.truncate(&1, inner))
  end

  defp draw_panel(screen, y, box_w, box_h, title) do
    screen
    |> Screen.fill_rect(@left, y, box_w, box_h, :p_fill)
    |> Screen.put_text(@left + 1, y, " " <> title <> " ", :p_title)
  end

  defp pad_rows(rows, row_count) do
    rows ++ List.duplicate({:blank, nil}, max(row_count - length(rows), 0))
  end

  # Pads (or clips) to an exact width so an overlay fully covers whatever it
  # is drawn on top of, leaving no trailing residue.
  defp pad(text, width) do
    t = truncate_words(text, width)
    t <> String.duplicate(" ", max(width - Screen.text_width(t), 0))
  end

  defp truncate_words(text, width) when width <= 3, do: Screen.truncate(text, width)

  defp truncate_words(text, width) do
    if Screen.text_width(text) <= width do
      text
    else
      limit = width - 3

      clipped =
        text
        |> Screen.truncate(limit)
        |> String.trim_trailing()

      clipped =
        if String.contains?(clipped, " ") do
          Regex.replace(~r/\s+\S*$/u, clipped, "")
        else
          clipped
        end

      clipped <> "..."
    end
  end
end
