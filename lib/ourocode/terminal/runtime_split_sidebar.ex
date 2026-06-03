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
    |> Enum.flat_map(&work_lines/1)
  end

  defp work_lines("label=current-task status=" <> status) do
    ["● PM interview", "  State " <> TranscriptRows.humanize(status)]
  end

  defp work_lines("label=delegated-work token=" <> token) do
    ["● Question ready", "  State " <> TranscriptRows.humanize(token)]
  end

  defp work_lines("task=" <> fields) do
    field_lines(fields, "task", "Task")
  end

  defp work_lines("agent=" <> fields) do
    field_lines(fields, "agent", "Agent")
  end

  defp work_lines(line), do: [TranscriptRows.humanize(line)]

  defp field_lines(fields, primary_key, fallback_label) do
    parsed = parse_fields(primary_key <> "=" <> fields)
    primary = Map.get(parsed, primary_key, fallback_label)
    state = Map.get(parsed, "state") || Map.get(parsed, "status")
    elapsed = Map.get(parsed, "elapsed")
    action = Map.get(parsed, "action")
    current = Map.get(parsed, "current")

    [
      "● " <> primary_label(fallback_label, primary),
      state_line(state, elapsed),
      action_line(action),
      current_line(current)
    ]
    |> Enum.reject(&blank?/1)
  end

  defp primary_label(label, value), do: label <> " " <> value

  defp state_line(nil, nil), do: nil
  defp state_line("", nil), do: nil
  defp state_line(nil, elapsed), do: "  Elapsed " <> TranscriptRows.humanize(elapsed)
  defp state_line("", elapsed), do: "  Elapsed " <> TranscriptRows.humanize(elapsed)

  defp state_line(state, nil) do
    "  State " <> TranscriptRows.humanize(state)
  end

  defp state_line(state, elapsed) do
    "  State " <> TranscriptRows.humanize(state) <> " · " <> TranscriptRows.humanize(elapsed)
  end

  defp action_line(nil), do: nil
  defp action_line(""), do: nil
  defp action_line(action), do: "  Action " <> TranscriptRows.humanize(action)

  defp current_line(nil), do: nil
  defp current_line(""), do: nil
  defp current_line(current), do: "  Now " <> TranscriptRows.humanize(current)

  defp parse_fields(fields) do
    ~r/(\w+)=([^=]+?)(?=\s+\w+=|$)/
    |> Regex.scan(fields)
    |> Map.new(fn [_match, key, value] -> {key, String.trim(value)} end)
  end

  defp blank?(value), do: value in [nil, ""]

  @doc false
  @spec wrap_lines([String.t()], pos_integer()) :: [String.t()]
  def wrap_lines(lines, w) when is_list(lines) do
    width = max(w - 1, 1)

    lines
    |> Enum.flat_map(fn line ->
      text = item_text(line)

      rows =
        text
        |> InterviewPanel.plain_line()
        |> TextWrap.wrap(width)

      case line do
        %{id: id} = item when is_binary(id) ->
          Enum.map(rows, &%{item | text: &1})

        %{text: _text} = item ->
          Enum.map(rows, &%{item | text: &1})

        _line ->
          rows
      end
    end)
    |> Enum.reject(&(item_text(&1) == ""))
  end

  @doc false
  def draw_section(screen, x, y, w, title, lines, body_h, opts \\ %{})

  def draw_section(screen, x, y, w, title, lines, body_h, opts)
      when w >= 4 and body_h >= 1 do
    if lines == [] do
      screen
    else
      draw_section_rows(screen, x, y, w, title, lines, body_h, opts)
    end
  end

  def draw_section(screen, _x, _y, _w, _title, _lines, _body_h, _opts), do: screen

  defp draw_section_rows(screen, x, y, w, title, lines, body_h, opts) do
    {status, status_style} = section_status(lines, opts)
    screen = Screen.put_text(screen, x, y, title, :p_title)

    screen =
      Screen.put_text(screen, x + String.length(title) + 1, y, status, status_style)

    rows =
      case lines do
        [] -> []
        lines -> lines |> Enum.take(body_h) |> Enum.map(&{item_text(&1), line_style(&1)})
      end

    rows
    |> Enum.with_index(1)
    |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
      Screen.put_text(acc, x, y + offset, Screen.truncate(text, w - 1), style)
    end)
  end

  @doc false
  def draw_activity(screen, x, y, w, title, lines, body_h, scroll, opts \\ %{})

  def draw_activity(screen, x, y, w, title, lines, body_h, scroll, opts)
      when w >= 4 and body_h >= 1 do
    if lines == [] do
      screen
    else
      draw_activity_rows(screen, x, y, w, title, lines, min(body_h, 4), scroll, opts)
    end
  end

  def draw_activity(screen, _x, _y, _w, _title, _lines, _body_h, _scroll, _opts), do: screen

  defp draw_activity_rows(screen, x, y, w, title, lines, body_h, scroll, opts) do
    rows =
      lines
      |> scroll_tail(body_h, scroll)
      |> Enum.map(&{&1, :p_muted})

    screen
    |> Screen.put_text(x, y, title, :p_title)
    |> Screen.put_text(
      x + String.length(title) + 1,
      y,
      Map.get(opts, :activity_status, "live"),
      Map.get(opts, :activity_status_style, :warn)
    )
    |> then(fn screen ->
      rows
      |> Enum.with_index(1)
      |> Enum.reduce(screen, fn {{text, style}, offset}, acc ->
        Screen.put_text(acc, x, y + offset, Screen.truncate(text, w - 1), style)
      end)
    end)
  end

  defp section_status([], _opts), do: {"idle", :p_muted}

  defp section_status(lines, opts) do
    cond do
      Enum.any?(lines, &(item_text(&1) =~ ~r/failed|error/i)) -> {"failed", :p_err}
      status = Map.get(opts, :status) -> {"● " <> status, Map.get(opts, :status_style, :p_accent)}
      true -> {"● live", :p_accent}
    end
  end

  defp line_style(%{style: style}) when is_atom(style), do: style

  defp line_style(line) do
    line = item_text(line)

    cond do
      line =~ ~r/failed|error/i -> :p_err
      line == "idle" -> :p_muted
      true -> :p_dim
    end
  end

  defp item_text(%{text: text}) when is_binary(text), do: text
  defp item_text(text) when is_binary(text), do: text
  defp item_text(item), do: InterviewPanel.plain_line(item)
end
