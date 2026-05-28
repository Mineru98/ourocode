defmodule Ourocode.Terminal.WonderNavigation do
  @moduledoc false

  alias Ourocode.Terminal.InterviewPanel

  @spec nav_event?(map(), String.t(), map() | nil, map() | nil) :: boolean()
  def nav_event?(%{key: k}, _buffer, _detection, _nav) when k in [:up, :down],
    do: true

  def nav_event?(%{key: k}, buffer, detection, nav) when k in [:left, :right] do
    buffer == "" and not active_free_answer?(detection, nav)
  end

  def nav_event?(%{key: :tab}, _buffer, _detection, _nav), do: true

  def nav_event?(%{key: :char, char: " "}, buffer, detection, nav) do
    buffer == "" and not active_free_answer?(detection, nav) and
      multi_select?(active_question(detection, nav))
  end

  def nav_event?(%{key: :char, char: c}, buffer, detection, nav) when c in ["h", "j", "k", "l"] do
    buffer == "" and not active_free_answer?(detection, nav)
  end

  def nav_event?(%{key: :char, char: c}, buffer, detection, nav) when is_binary(c) do
    buffer == "" and c =~ ~r/^[1-9]$/ and not active_free_answer?(detection, nav)
  end

  def nav_event?(_event, _buffer, _detection, _nav), do: false

  @spec active_question(map() | nil, map() | nil) :: map() | nil
  def active_question(detection, nav) do
    questions = questions(detection)

    case questions do
      [] ->
        nil

      _questions ->
        qi = clamp_index(nav_qidx(nav), length(questions))
        Enum.at(questions, qi)
    end
  end

  @spec active_free_answer?(map() | nil, map() | nil) :: boolean()
  def active_free_answer?(detection, nav) do
    questions = questions(detection)

    case questions do
      [] ->
        false

      _questions ->
        qi = clamp_index(nav_qidx(nav), length(questions))
        question = Enum.at(questions, qi)
        opt_count = question |> Map.get(:options, []) |> length()
        current = if multi_select?(question), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)

        current == opt_count
    end
  end

  @spec free_text_payload(map() | nil, map() | nil, String.t()) :: map()
  def free_text_payload(detection, nav, answer) when is_binary(answer) do
    payload = %{"freeText" => answer}

    case active_question(detection, nav) do
      %{} = question ->
        case Map.get(question, :id) || Map.get(question, "id") do
          id when is_binary(id) and id != "" -> Map.put(payload, "questionId", id)
          _other -> payload
        end

      _none ->
        payload
    end
  end

  @spec after_event(map() | nil, map() | nil, map()) :: map() | nil
  def after_event(detection, nav, event) do
    questions = questions(detection)
    n = length(questions)

    if n > 0 do
      nav = nav || InterviewPanel.default_nav(detection, nil)

      qi = clamp_index(nav_qidx(nav), n)
      question = Enum.at(questions, qi)
      opt_count = question |> Map.get(:options, []) |> length()
      multi? = multi_select?(question)
      current = if multi?, do: nav_cursor(nav, qi), else: nav_pick(nav, qi)

      apply_nav(event, nav, qi, n, opt_count, multi?, current)
    end
  end

  @spec selections(map() | nil, map() | nil) :: [pos_integer() | [pos_integer()]]
  def selections(detection, nav) do
    detection
    |> questions()
    |> Enum.with_index()
    |> Enum.map(fn {question, qi} ->
      if multi_select?(question) do
        nav_multi_pick(nav, qi)
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.map(&(&1 + 1))
      else
        nav_pick(nav, qi) + 1
      end
    end)
  end

  @spec any_free_answer_selected?(map() | nil, map() | nil) :: boolean()
  def any_free_answer_selected?(detection, nav) do
    detection
    |> questions()
    |> Enum.with_index()
    |> Enum.any?(fn {question, qi} ->
      opt_count = question |> Map.get(:options, []) |> length()
      current = if multi_select?(question), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)
      current == opt_count
    end)
  end

  defp apply_nav(%{key: :tab}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: rem(qi + 1, max(n, 1))}
  end

  defp apply_nav(%{key: :left}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: Integer.mod(qi - 1, max(n, 1))}
  end

  defp apply_nav(%{key: :right}, nav, qi, n, _opts, _multi?, _current) do
    %{nav | qidx: rem(qi + 1, max(n, 1))}
  end

  defp apply_nav(%{key: :char, char: "h"}, nav, qi, n, opts, multi?, current) do
    apply_nav(%{key: :left}, nav, qi, n, opts, multi?, current)
  end

  defp apply_nav(%{key: :char, char: "l"}, nav, qi, n, opts, multi?, current) do
    apply_nav(%{key: :right}, nav, qi, n, opts, multi?, current)
  end

  defp apply_nav(%{key: :up}, nav, qi, _n, _opts, multi?, current) do
    put_cursor_or_pick(nav, qi, max(current - 1, 0), multi?)
  end

  defp apply_nav(%{key: :down}, nav, qi, _n, opt_count, multi?, current) do
    put_cursor_or_pick(nav, qi, min(current + 1, opt_count), multi?)
  end

  defp apply_nav(%{key: :char, char: "k"}, nav, qi, n, opts, multi?, current) do
    apply_nav(%{key: :up}, nav, qi, n, opts, multi?, current)
  end

  defp apply_nav(%{key: :char, char: "j"}, nav, qi, n, opts, multi?, current) do
    apply_nav(%{key: :down}, nav, qi, n, opts, multi?, current)
  end

  defp apply_nav(%{key: :char, char: " "}, nav, qi, _n, opt_count, true, _current) do
    cursor = nav_cursor(nav, qi)
    if cursor < opt_count, do: toggle_multi_pick(nav, qi, cursor), else: nav
  end

  defp apply_nav(%{key: :char, char: c}, nav, qi, _n, opt_count, multi?, _current)
       when c in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] do
    idx = String.to_integer(c) - 1
    if idx < opt_count, do: put_cursor_or_pick(nav, qi, idx, multi?), else: nav
  end

  defp apply_nav(_event, nav, _qi, _n, _opts, _multi?, _current), do: nav

  defp put_cursor_or_pick(nav, qi, idx, true) do
    %{nav | cursors: Map.put(Map.get(nav, :cursors, %{}), qi, idx)}
  end

  defp put_cursor_or_pick(nav, qi, idx, false), do: put_pick(nav, qi, idx)

  defp put_pick(nav, qi, idx) do
    %{nav | picks: Map.put(Map.get(nav, :picks, %{}), qi, idx)}
  end

  defp toggle_multi_pick(nav, qi, idx) do
    picks = Map.get(nav, :picks, %{})
    selected = Map.get(picks, qi, MapSet.new())

    selected =
      if MapSet.member?(selected, idx),
        do: MapSet.delete(selected, idx),
        else: MapSet.put(selected, idx)

    %{nav | picks: Map.put(picks, qi, selected)}
  end

  defp questions(detection), do: InterviewPanel.wonder_questions(detection)
  defp nav_qidx(nav), do: InterviewPanel.nav_qidx(nav)
  defp nav_cursor(nav, qi), do: InterviewPanel.nav_cursor(nav, qi)
  defp nav_pick(nav, qi), do: InterviewPanel.nav_pick(nav, qi)
  defp nav_multi_pick(nav, qi), do: InterviewPanel.nav_multi_pick(nav, qi)
  defp multi_select?(question), do: InterviewPanel.multi_select?(question)
  defp clamp_index(idx, count), do: max(0, min(idx, count - 1))
end
