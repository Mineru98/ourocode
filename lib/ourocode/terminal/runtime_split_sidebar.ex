defmodule Ourocode.Terminal.RuntimeSplitSidebar do
  @moduledoc false

  alias Ourocode.Terminal.{InterviewPanel, Screen, TextWrap, TranscriptRows}

  @doc false
  @spec scroll_tail([String.t()], non_neg_integer(), non_neg_integer()) :: [String.t()]
  def scroll_tail(lines, body_h, scroll) do
    total = length(lines)

    if total <= body_h do
      lines
    else
      offset = max(scroll, 0)
      start = max(total - body_h - offset, 0)
      lines |> Enum.slice(start, body_h)
    end
  end

  @doc false
  @spec section_heights([String.t()], [String.t()], non_neg_integer()) ::
          {pos_integer(), pos_integer()}
  def section_heights(parent_lines, child_lines, region) do
    overhead = 2
    half = max(div(region, 2), 1)
    p_body = min(max(length(parent_lines), 1), half)
    c_body = min(max(length(child_lines), 1), half)

    if p_body + overhead + c_body + overhead <= region do
      {p_body, c_body}
    else
      p = max(min(p_body, region - 2 * overhead - 1), 1)
      c = max(region - (p + overhead) - overhead, 1)
      {p, c}
    end
  end

  @doc false
  @spec pane_lines([String.t()], String.t()) :: [String.t()]
  def pane_lines(body, prefix) do
    body
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
    |> Enum.reject(&(&1 in ["empty", ""]))
    |> Enum.map(&TranscriptRows.humanize/1)
  end

  @doc false
  @spec wrap_lines([String.t()], pos_integer()) :: [String.t()]
  def wrap_lines(lines, w) when is_list(lines) do
    width = max(w - 1, 1)

    lines
    |> Enum.flat_map(fn line ->
      line
      |> InterviewPanel.plain_line()
      |> TextWrap.wrap(width)
    end)
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  def draw_section(screen, x, y, w, title, lines, body_h)
      when w >= 4 and body_h >= 1 do
    {status, status_style} = section_status(lines)
    screen = Screen.put_text(screen, x, y, title, :p_title)

    screen =
      Screen.put_text(screen, x + String.length(title) + 1, y, status, status_style)

    rows =
      case lines do
        [] -> [{"idle", :p_muted}]
        lines -> lines |> Enum.take(-body_h) |> Enum.map(&{&1, line_style(&1)})
      end

    rows
    |> Enum.with_index(1)
    |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
      Screen.put_text(acc, x, y + offset, Screen.truncate(text, w - 1), style)
    end)
  end

  def draw_section(screen, _x, _y, _w, _title, _lines, _body_h), do: screen

  @doc false
  def draw_activity(screen, x, y, w, title, lines, body_h, scroll)
      when w >= 4 and body_h >= 1 do
    rows =
      lines
      |> scroll_tail(body_h, scroll)
      |> Enum.map(&{&1, :p_muted})

    screen
    |> Screen.put_text(x, y, title, :p_title)
    |> Screen.put_text(x + String.length(title) + 1, y, "live", :warn)
    |> then(fn screen ->
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
        Screen.put_text(acc, x, y + offset, Screen.truncate(text, w - 1), style)
      end)
    end)
  end

  def draw_activity(screen, _x, _y, _w, _title, _lines, _body_h, _scroll), do: screen

  defp section_status([]), do: {"idle", :p_muted}

  defp section_status(lines) do
    cond do
      Enum.any?(lines, &(&1 =~ ~r/failed|error/i)) -> {"failed", :p_err}
      true -> {"live", :p_accent}
    end
  end

  defp line_style(line) do
    cond do
      line =~ ~r/failed|error/i -> :p_err
      line == "idle" -> :p_muted
      true -> :p_dim
    end
  end
end
