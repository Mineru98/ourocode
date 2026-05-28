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

    rows =
      lines
      |> Enum.flat_map(&wrap_logical_line(&1, inner))
      |> Enum.take(max_rows)

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
