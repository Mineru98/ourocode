defmodule Ourocode.Terminal.InterviewPanel.WonderPicker do
  @moduledoc """
  WonderTool picker navigation defaults and text rendering.
  """

  alias Ourocode.Terminal.InterviewPanel.Text

  @spec lines(map(), map() | nil) :: [String.t()]
  def lines(detection, nav) do
    questions = questions(detection)
    n = length(questions)

    cond do
      n == 0 ->
        []

      Map.get(nav || %{}, :review?, false) ->
        review_lines(questions, nav)

      true ->
        qi = clamp_index(nav_qidx(nav), n)
        q = Enum.at(questions, qi)
        cursor = if multi_select?(q), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)
        block_lines(q, qi, n, cursor, nav_multi_pick(nav, qi))
    end
  end

  @spec default_nav(map(), map() | nil) :: map()
  def default_nav(detection, current_nav) do
    req_id = req_id(detection)

    if is_map(current_nav) and Map.get(current_nav, :req_id) == req_id do
      current_nav
    else
      %{
        req_id: req_id,
        qidx: 0,
        cursors: default_cursors(detection),
        picks: default_picks(detection)
      }
    end
  end

  @spec question_count(map()) :: non_neg_integer()
  def question_count(detection), do: detection |> questions() |> length()

  @spec questions(map()) :: [map()]
  def questions(detection) do
    case detection do
      %{request: %{questions: questions}} when is_list(questions) -> questions
      _other -> []
    end
  end

  @spec nav_qidx(map() | nil) :: integer()
  def nav_qidx(%{qidx: qidx}) when is_integer(qidx), do: qidx
  def nav_qidx(_nav), do: 0

  @spec nav_cursor(map() | nil, integer()) :: integer()
  def nav_cursor(%{cursors: cursors}, qi) when is_map(cursors), do: Map.get(cursors, qi, 0)
  def nav_cursor(nav, qi), do: nav_pick(nav, qi)

  @spec nav_pick(map() | nil, integer()) :: integer()
  def nav_pick(%{picks: picks}, qi) when is_map(picks), do: Map.get(picks, qi, 0)
  def nav_pick(_nav, _qi), do: 0

  @spec nav_multi_pick(map() | nil, integer()) :: MapSet.t()
  def nav_multi_pick(%{picks: picks}, qi) when is_map(picks) do
    case Map.get(picks, qi) do
      %MapSet{} = set -> set
      idx when is_integer(idx) -> MapSet.new([idx])
      _other -> MapSet.new()
    end
  end

  def nav_multi_pick(_nav, _qi), do: MapSet.new()

  @spec multi_select?(map()) :: boolean()
  def multi_select?(question) when is_map(question) do
    Map.get(question, :multi_select?, false) == true or
      Map.get(question, "multi_select", false) == true or
      Map.get(question, "multiSelect", false) == true
  end

  def multi_select?(_question), do: false

  defp review_lines(questions, nav) do
    total = length(questions)

    review_rows =
      questions
      |> Enum.with_index()
      |> Enum.flat_map(fn {q, qi} ->
        answer = review_answer_label(q, nav, qi)
        ["[#{qi + 1}/#{total}] #{Text.md_text(Map.get(q, :header, "Question"))}", "  #{answer}"]
      end)

    [
      "Review answers before submit",
      "Enter confirms all selections, Esc returns to main session"
      | review_rows
    ]
  end

  defp review_answer_label(q, nav, qi) do
    options = Map.get(q, :options, [])

    if multi_select?(q) do
      nav_multi_pick(nav, qi)
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map_join(", ", &option_label(options, &1))
      |> case do
        "" -> "No options selected"
        labels -> labels
      end
    else
      option_label(options, nav_pick(nav, qi))
    end
  end

  defp option_label(options, index) do
    options
    |> Enum.at(index)
    |> case do
      %{} = opt -> Text.md_text(Map.get(opt, :label, "Option #{index + 1}"))
      _none -> "Free answer"
    end
  end

  defp block_lines(q, qi, n, cursor, multi_picks) do
    progress =
      if n > 1 do
        0..(n - 1)
        |> Enum.map_join("", fn idx -> if idx == qi, do: "*", else: "." end)
        |> then(&"  [#{&1}]")
      else
        ""
      end

    header =
      if n > 1,
        do: "Question #{qi + 1}/#{n}#{progress}  ·  #{Text.md_text(Map.get(q, :header, ""))}",
        else: Text.md_text(Map.get(q, :header, ""))

    opt_lines =
      q
      |> Map.get(:options, [])
      |> Enum.with_index()
      |> Enum.map(fn {opt, oi} ->
        row_cursor = if oi == cursor, do: ">", else: " "
        label = Text.md_text(Map.get(opt, :label, ""))
        desc = Text.md_text(Map.get(opt, :description, ""))

        marker =
          if multi_select?(q),
            do: "#{if(MapSet.member?(multi_picks, oi), do: "[x]", else: "[ ]")} [#{oi + 1}]",
            else: "[#{oi + 1}]"

        "#{row_cursor}#{row_cursor} #{marker} #{label} - #{desc}"
      end)

    free_row_cursor = if cursor == length(opt_lines), do: ">", else: " "
    free_row = "#{free_row_cursor}#{free_row_cursor} [Free answer] type below, then Enter"

    [header, Text.md_text(Map.get(q, :question, "")) | opt_lines ++ [free_row]]
  end

  defp req_id(detection) do
    case Map.get(detection, :request_id) do
      id when is_binary(id) and id != "" -> id
      _none -> "wt-" <> Integer.to_string(:erlang.phash2(questions(detection)))
    end
  end

  defp default_picks(detection) do
    detection
    |> questions()
    |> Enum.with_index()
    |> Map.new(fn {q, qi} ->
      opts = Map.get(q, :options, [])
      idx = Enum.find_index(opts, &Map.get(&1, :recommended?, false)) || 0
      if multi_select?(q), do: {qi, MapSet.new([idx])}, else: {qi, idx}
    end)
  end

  defp default_cursors(detection) do
    detection
    |> questions()
    |> Enum.with_index()
    |> Enum.filter(fn {q, _qi} -> multi_select?(q) end)
    |> Map.new(fn {_q, qi} -> {qi, 0} end)
  end

  defp clamp_index(_i, 0), do: 0
  defp clamp_index(i, n), do: Integer.mod(i, n)
end
