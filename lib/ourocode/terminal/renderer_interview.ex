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
        "" -> "Free answer: type here, then Enter"
        text -> "Free answer: " <> text
      end

    hint = "j/k or Up/Dn select   h/l or Left/Right question   Esc main session   " <> hint

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
      |> Screen.put_text(@left, top, "|", :accent)
      |> Screen.put_text(@body, top, clip(marker, inner), :brand)

    screen =
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, i}, acc ->
        acc
        |> Screen.put_text(@left, top + i, "|", :accent)
        |> Screen.put_text(@body, top + i, clip(text, inner), style)
      end)

    hint_row = top + length(rows) + 1

    screen =
      screen
      |> Screen.put_text(@left, hint_row, "|", :accent)
      |> Screen.put_text(@body, hint_row, clip(hint, inner), :muted)

    {screen, 1 + length(rows) + 1}
  end

  defp wrap_focus_line({text, style}, inner) when is_binary(text) do
    wrap_styled(text, focus_style(style), inner)
  end

  defp wrap_focus_line(:rule, inner) do
    [{String.duplicate("-", inner), :p_muted}]
  end

  defp wrap_focus_line(line, inner) when is_binary(line) do
    style =
      cond do
        String.starts_with?(line, ">> ") -> :p_accent
        String.starts_with?(line, "   [") -> :p_dim
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

  defp wrap_logical_line(:rule, inner) do
    [{String.duplicate("─", inner), :muted}]
  end

  defp wrap_logical_line(line, inner) when is_binary(line) do
    style = if String.starts_with?(line, ">> "), do: :accent, else: :strong
    wrap_styled(line, style, inner)
  end

  defp wrap_styled(text, style, inner) do
    text
    |> wrap_text(inner)
    |> Enum.with_index()
    |> Enum.map(fn
      {seg, 0} -> {seg, style}
      {seg, _n} -> {"  " <> seg, style}
    end)
  end

  @doc false
  @spec wrap_text(String.t(), pos_integer()) :: [String.t()]
  def wrap_text(text, width), do: TextWrap.wrap(text, width)

  defp clip(text, max_width), do: Screen.truncate(text, max_width)
end
