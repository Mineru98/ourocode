defmodule Ourocode.Terminal.RendererInterview do
  @moduledoc false

  alias Ourocode.Terminal.{Screen, TextWrap}

  @left 2
  @body 4

  @spec draw_focus(
          Screen.t(),
          pos_integer(),
          integer(),
          integer(),
          {String.t(), [term()], String.t()},
          String.t()
        ) :: Screen.t()
  def draw_focus(screen, width, top, bottom, {marker, lines, hint}, prompt_buffer) do
    panel_x = @left
    panel_w = max(width - 2 * @left, 1)
    panel_h = max(bottom - top + 1, 1)
    inner_x = panel_x + 2
    inner_w = max(panel_w - 4, 1)
    max_content = max(panel_h - 5, 1)

    rows =
      lines
      |> Enum.flat_map(&wrap_focus_line(&1, inner_w))
      |> Enum.take(max_content)

    input =
      case String.trim(prompt_buffer) do
        "" -> ""
        "/" <> _rest = text -> "Command: " <> text
        text -> "Custom answer: " <> text
      end

    hint = responsive_key_hint(inner_w, hint)

    screen =
      screen
      |> Screen.fill_rect(0, top, width, panel_h, :p_fill)
      |> Screen.put_text(inner_x, top + 1, clip(marker, inner_w), :p_title)

    screen =
      rows
      |> Enum.with_index(2)
      |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
        Screen.put_text(acc, inner_x, top + offset, clip(text, inner_w), style)
      end)

    hint_top = bottom - 2

    screen
    |> Screen.put_text(inner_x, hint_top, clip(input, inner_w), :p_accent)
    |> Screen.put_text(inner_x, hint_top + 1, clip(hint, inner_w), :p_muted)
  end

  # The pinned, prominent interview block uses an accent rail, marker,
  # emphasized content, and dim key hint. Long lines word-wrap to the
  # left-column width instead of truncating or bleeding into the right pane.
  @spec draw_block(
          Screen.t(),
          integer(),
          pos_integer(),
          String.t(),
          [term()],
          String.t(),
          pos_integer()
        ) :: {Screen.t(), pos_integer()}
  def draw_block(screen, top, width, marker, lines, hint, max_rows) do
    inner = max(width - @body - @left, 1)

    rows = block_rows(lines, inner, max_rows)

    screen =
      screen
      |> Screen.put_text(@left, top, "│", :accent)
      |> Screen.put_text(@body, top, clip(marker, inner), :brand)

    screen =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, i}, acc ->
        acc
        |> Screen.put_text(@left, top + i, "│", :accent)
        |> Screen.put_text(@body, top + i, clip(text, inner), style)
      end)

    hint_row = top + length(rows) + 1

    screen =
      screen
      |> Screen.put_text(@left, hint_row, "│", :accent)
      |> Screen.put_text(@body, hint_row, clip(hint, inner), :muted)

    {screen, 1 + length(rows) + 1}
  end

  @doc false
  @spec ledger_hit_map(
          :block | :focus,
          integer(),
          pos_integer(),
          [term()],
          pos_integer(),
          map()
        ) :: map()
  def ledger_hit_map(:block, top, width, lines, max_rows, block_ids) do
    inner = max(width - @body - @left, 1)

    lines
    |> logical_rows(:block, inner)
    |> Enum.take(max_rows)
    |> hit_map_from_rows(top + 1, width, block_ids)
  end

  def ledger_hit_map(:focus, top, width, lines, max_content, block_ids) do
    panel_w = max(width - 2 * @left, 1)
    inner_w = max(panel_w - 4, 1)

    lines
    |> logical_rows(:focus, inner_w)
    |> Enum.take(max_content)
    |> hit_map_from_rows(top + 2, width, block_ids)
  end

  defp block_rows(lines, inner, max_rows) do
    lines
    |> Enum.flat_map(&wrap_logical_line(&1, inner))
    |> Enum.take(max_rows)
  end

  defp logical_rows(lines, mode, inner) do
    lines
    |> Enum.flat_map(fn line ->
      index = ledger_question_index(line)

      line
      |> wrap_line_for_mode(mode, inner)
      |> Enum.map(fn row -> {row, index} end)
    end)
  end

  defp wrap_line_for_mode(line, :focus, inner), do: wrap_focus_line(line, inner)
  defp wrap_line_for_mode(line, :block, inner), do: wrap_logical_line(line, inner)

  defp hit_map_from_rows(rows, start_y, width, block_ids) do
    rows
    |> Enum.with_index(start_y)
    |> Enum.reduce(%{}, fn {{_row, index}, y}, acc ->
      case Map.get(block_ids, index) do
        id when is_binary(id) ->
          Map.put(acc, y + 1, %{id: id, x1: 1, x2: width})

        _none ->
          acc
      end
    end)
  end

  defp ledger_question_index({text, _style}) when is_binary(text), do: ledger_question_index(text)

  defp ledger_question_index(text) when is_binary(text) do
    case Regex.run(~r/\A[+\-> ] \[[^\]]+\] Q(\d+)\b/u, text) do
      [_match, index] -> String.to_integer(index)
      _no_match -> nil
    end
  end

  defp ledger_question_index(_line), do: nil

  defp wrap_focus_line({text, style}, inner) when is_binary(text) do
    wrap_styled(text, focus_style(style), inner)
  end

  defp wrap_focus_line(:rule, _inner) do
    [{"", :p_muted}]
  end

  defp wrap_focus_line(line, inner) when is_binary(line) do
    line = decorate_picker_line(line)

    style =
      cond do
        String.starts_with?(line, "● ") -> :p_accent
        String.starts_with?(line, "○ ") -> :p_dim
        true -> :p_title
      end

    wrap_styled(line, style, inner)
  end

  defp focus_style(:warn), do: :p_accent
  defp focus_style(:err), do: :p_err
  defp focus_style(:dim), do: :p_dim
  defp focus_style(:muted), do: :p_muted
  defp focus_style(:accent), do: :p_accent
  defp focus_style(_style), do: :p_title

  # A logical line keeps one style for all of its wrapped segments;
  # continuation segments are indented two columns so a wrapped item still
  # reads as one.
  defp wrap_logical_line({text, style}, inner) when is_binary(text) do
    wrap_styled(text, style, inner)
  end

  defp wrap_logical_line(:rule, _inner) do
    [{"", :muted}]
  end

  defp wrap_logical_line(line, inner) when is_binary(line) do
    line = decorate_picker_line(line)
    style = if String.starts_with?(line, "● "), do: :accent, else: :strong
    wrap_styled(line, style, inner)
  end

  defp decorate_picker_line(">> " <> rest), do: "● >> " <> rest
  defp decorate_picker_line("   [" <> rest), do: "○ [" <> rest
  defp decorate_picker_line(line), do: line

  defp wrap_styled(text, style, inner) do
    continuation = "  "
    width = max(inner - Screen.text_width(continuation), 1)

    text
    |> wrap_text(width)
    |> Enum.with_index()
    |> Enum.map(fn
      {seg, 0} -> {seg, style}
      {seg, _n} -> {continuation <> seg, style}
    end)
  end

  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width), do: TextWrap.wrap(text, width)

  defp responsive_key_hint(inner, hint) when inner < 62 do
    base = "Enter confirm"
    hint = secondary_hint(hint)

    if hint == "" do
      base
    else
      base <> "  " <> hint
    end
  end

  defp responsive_key_hint(_inner, hint) do
    base = "Enter confirm"
    hint = secondary_hint(hint)

    if hint == "" do
      base
    else
      base <> "   " <> hint
    end
  end

  defp secondary_hint(hint) do
    hint = String.downcase(String.trim(to_string(hint)))

    cond do
      hint == "" -> ""
      String.contains?(hint, "tab") -> "Tab switches question"
      String.contains?(hint, "cancel") -> "/cancel stops"
      true -> ""
    end
  end

  defp clip(text, max_width), do: Screen.truncate(text, max_width)
end
