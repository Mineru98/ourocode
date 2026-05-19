defmodule Ourocode.Terminal.Screen do
  @moduledoc """
  Pure ANSI screen-buffer compositor with row-level diffing.

  The Elixir runtime stays the source of truth for the render model; this
  module is a presentation-only cell grid. Callers paint boxes and text by
  coordinate, then either emit a full ANSI frame or a minimal diff against
  the previously emitted buffer so a persistent terminal app redraws in
  place instead of scrolling an append log. It owns no IO or process state.
  """

  @reset "\e[0m"

  # 24-bit truecolor design system. The Rust tty helper writes frames verbatim
  # to the host terminal (no SGR rewriting, no capability gating), so colour
  # depth is the terminal's, not ours to fear. Identity is one warm gold accent
  # used rarely (wordmark, caret, selection, live pulse, interview rail) over a
  # cool neutral ramp; body text stays the terminal's own foreground so it
  # adapts to the user's theme. Restraint, not saturation, carries the look.
  # Every entry leads with `0;` so each styled run is fully self-contained:
  # weight and colour reset before they are re-set, so a bold run never bleeds
  # into the dim run beside it on the same row.
  @styles %{
    brand: "\e[0;1;38;2;227;179;65m",
    accent: "\e[0;38;2;227;179;65m",
    strong: "\e[0;1;38;2;245;245;247m",
    label: "\e[0;1;38;2;142;142;150m",
    dim: "\e[0;38;2;141;141;149m",
    muted: "\e[0;38;2;101;101;110m",
    border: "\e[0;38;2;58;58;64m",
    title: "\e[0;1;38;2;227;179;65m",
    ok: "\e[0;38;2;63;185;80m",
    warn: "\e[0;38;2;210;153;34m",
    err: "\e[0;38;2;248;81;73m",
    placeholder: "\e[0;38;2;84;84;93m",
    text: "\e[0m",
    # Panel surface: a self-contained shaded sidebar that owns both its
    # background and foreground so contrast is guaranteed regardless of the
    # host terminal theme (the global palette stays adaptive). A subtle light
    # fill separates the right pane without any rule or box character.
    p_fill: "\e[0;48;2;233;233;236m",
    p_title: "\e[0;1;48;2;233;233;236;38;2;31;31;36m",
    p_accent: "\e[0;48;2;233;233;236;38;2;150;108;22m",
    p_dim: "\e[0;48;2;233;233;236;38;2;77;77;85m",
    p_muted: "\e[0;48;2;233;233;236;38;2;135;135;143m",
    p_err: "\e[0;48;2;233;233;236;38;2;179;38;30m"
  }

  @type style ::
          :brand
          | :accent
          | :strong
          | :label
          | :dim
          | :muted
          | :border
          | :title
          | :ok
          | :warn
          | :err
          | :placeholder
          | :text
          | :p_fill
          | :p_title
          | :p_accent
          | :p_dim
          | :p_muted
          | :p_err
  @type t :: %{
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          required(:rows) => %{
            optional(non_neg_integer()) => %{optional(non_neg_integer()) => {String.t(), style()}}
          }
        }

  @doc """
  Builds an empty `width` x `height` screen buffer.
  """
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(width, height) when width > 0 and height > 0 do
    %{width: width, height: height, rows: %{}}
  end

  @doc """
  Writes `text` starting at `{x, y}`, clipped to the screen width.
  """
  @spec put_text(t(), non_neg_integer(), non_neg_integer(), String.t(), style()) :: t()
  def put_text(%{width: width, height: height} = screen, x, y, text, style \\ :text)
      when is_integer(x) and is_integer(y) and is_binary(text) do
    if y < 0 or y >= height do
      screen
    else
      text
      |> String.graphemes()
      |> Enum.reduce({screen, x}, fn grapheme, {acc, col} ->
        w = char_width(grapheme)

        cond do
          col < 0 or col + w > width ->
            {acc, col + w}

          w == 2 ->
            acc =
              acc
              |> put_cell(col, y, {grapheme, style})
              |> put_cell(col + 1, y, {:cont, style})

            {acc, col + 2}

          true ->
            {put_cell(acc, col, y, {grapheme, style}), col + 1}
        end
      end)
      |> elem(0)
    end
  end

  @doc """
  Paints a `w` x `h` rectangle of spaces in `style` from `{x, y}`, clipped to
  the screen. Used to lay a shaded surface down before drawing content on top
  of it; content drawn afterwards (in a style carrying the same background)
  keeps the fill continuous. `to_lines/1` trims the spaces, so a fill never
  changes the plain-text projection.
  """
  @spec fill_rect(t(), non_neg_integer(), non_neg_integer(), integer(), integer(), style()) :: t()
  def fill_rect(%{width: width, height: height} = screen, x, y, w, h, style)
      when is_integer(x) and is_integer(y) do
    xs = max(x, 0)..min(x + w - 1, width - 1)//1
    ys = max(y, 0)..min(y + h - 1, height - 1)//1

    Enum.reduce(ys, screen, fn row, acc ->
      Enum.reduce(xs, acc, fn col, inner ->
        put_cell(inner, col, row, {" ", style})
      end)
    end)
  end

  @doc "Display columns a grapheme occupies (CJK/fullwidth = 2, else 1)."
  @spec char_width(String.t()) :: 1 | 2
  def char_width(grapheme) do
    case grapheme do
      <<cp::utf8, _::binary>> -> if wide?(cp), do: 2, else: 1
      _ -> 1
    end
  end

  @doc "Total display width of a string."
  @spec text_width(String.t()) :: non_neg_integer()
  def text_width(text) do
    text |> String.graphemes() |> Enum.reduce(0, &(&2 + char_width(&1)))
  end

  @doc "Truncates `text` to at most `max` display columns."
  @spec truncate(String.t(), integer()) :: String.t()
  def truncate(_text, max) when max <= 0, do: ""

  def truncate(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      w = char_width(g)
      if used + w > max, do: {:halt, {acc, used}}, else: {:cont, {[g | acc], used + w}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp wide?(cp) do
    (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0x303E) or
      (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x3400 and cp <= 0x4DBF) or
      (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xA000 and cp <= 0xA4CF) or
      (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
      (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
      (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF) or
      (cp >= 0x20000 and cp <= 0x3FFFD)
  end

  @doc """
  Draws a clean rounded box with an optional inline title in the top border.
  """
  @spec box(
          t(),
          non_neg_integer(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t() | nil,
          style()
        ) ::
          t()
  def box(screen, x, y, w, h, title \\ nil, style \\ :border)
      when w >= 2 and h >= 2 do
    top = box_top(w, title)
    bottom = "+" <> String.duplicate("-", w - 2) <> "+"

    screen
    |> put_text(x, y, top, style)
    |> draw_sides(x, y, w, h, style)
    |> put_text(x, y + h - 1, bottom, style)
  end

  @doc """
  Renders the full buffer as a cursor-home ANSI frame.
  """
  @spec to_ansi(t()) :: iodata()
  def to_ansi(%{height: height} = screen) do
    body =
      Enum.map(0..(height - 1), fn y ->
        ["\e[", Integer.to_string(y + 1), ";1H\e[2K", render_row(screen, y)]
      end)

    # Clear the whole viewport first so a shrunk frame leaves no orphan rows
    # below it and a resized terminal cannot show stale columns.
    ["\e[2J\e[H", body, @reset]
  end

  @doc """
  Emits ANSI updates only for rows that changed since `previous`.

  Returns `{iodata, screen}`; the returned screen is `current` and should
  be passed back as `previous` on the next diff.
  """
  @spec diff(t() | nil, t()) :: {iodata(), t()}
  def diff(nil, current), do: {to_ansi(current), current}

  def diff(%{width: pw, height: ph}, %{width: cw, height: ch} = current)
      when pw != cw or ph != ch do
    {to_ansi(current), current}
  end

  def diff(previous, %{height: height} = current) do
    changes =
      Enum.reduce(0..(height - 1), [], fn y, acc ->
        if render_row(previous, y) == render_row(current, y) do
          acc
        else
          [["\e[", Integer.to_string(y + 1), ";1H\e[2K", render_row(current, y)] | acc]
        end
      end)

    {[Enum.reverse(changes), @reset], current}
  end

  @doc """
  Projects the buffer to plain text rows (styles stripped) for assertions.
  """
  @spec to_lines(t()) :: [String.t()]
  def to_lines(%{width: width, height: height, rows: rows}) do
    Enum.map(0..(height - 1), fn y ->
      row = Map.get(rows, y, %{})

      0..(width - 1)
      |> Enum.map(fn x ->
        case Map.get(row, x) do
          {:cont, _style} -> ""
          {grapheme, _style} -> grapheme
          nil -> " "
        end
      end)
      |> Enum.join()
      |> String.trim_trailing()
    end)
  end

  defp box_top(w, nil), do: "+" <> String.duplicate("-", w - 2) <> "+"

  defp box_top(w, title) do
    label = " " <> title <> " "
    inner = w - 2

    if String.length(label) + 1 >= inner do
      box_top(w, nil)
    else
      fill = inner - String.length(label) - 1
      "+-" <> label <> String.duplicate("-", fill) <> "+"
    end
  end

  defp draw_sides(screen, x, y, w, h, style) do
    Enum.reduce(1..(h - 2), screen, fn offset, acc ->
      acc
      |> put_text(x, y + offset, "|", style)
      |> put_text(x + w - 1, y + offset, "|", style)
    end)
  end

  defp put_cell(%{rows: rows} = screen, x, y, cell) do
    row = rows |> Map.get(y, %{}) |> Map.put(x, cell)
    %{screen | rows: Map.put(rows, y, row)}
  end

  defp render_row(%{width: width, rows: rows}, y) do
    row = Map.get(rows, y, %{})

    {segments, last_style} =
      Enum.reduce(0..(width - 1), {[], nil}, fn x, {segments, current_style} ->
        case Map.get(row, x, {" ", :text}) do
          {:cont, _style} ->
            # Second half of a wide glyph: the glyph itself already advanced
            # the terminal two columns, so emit nothing here.
            {segments, current_style}

          {grapheme, style} ->
            if style == current_style do
              {[grapheme | segments], current_style}
            else
              {[grapheme, Map.fetch!(@styles, style) | segments], style}
            end
        end
      end)

    text = segments |> Enum.reverse() |> IO.iodata_to_binary()

    if last_style in [nil, :text], do: text, else: text <> @reset
  end
end
