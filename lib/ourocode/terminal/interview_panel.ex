defmodule Ourocode.Terminal.InterviewPanel do
  @moduledoc """
  Pure text rendering helpers for interview, wonderTool, and MCP activity panes.
  """

  alias Ourocode.Terminal.InterviewPanel.Dialogue
  alias Ourocode.Terminal.InterviewPanel.Hints
  alias Ourocode.Terminal.InterviewPanel.Status
  alias Ourocode.Terminal.InterviewPanel.Text
  alias Ourocode.Terminal.InterviewPanel.WonderPicker
  alias Ourocode.Terminal.InterviewLiveState

  @spec dialogue_rows(map(), boolean()) :: [{String.t(), atom()} | :rule]
  def dialogue_rows(result, drop_trailing_mcp?) do
    result
    |> interview_state()
    |> Dialogue.rows(drop_trailing_mcp?)
  end

  @spec interview_working_lines(map(), integer()) :: [String.t()]
  def interview_working_lines(result, tick) do
    iv = interview_state(result)
    trace = if iv, do: List.first(Map.get(iv, :router, [])), else: nil

    if paused?(result) or (iv && Map.get(iv, :complete) && is_nil(trace)) do
      []
    else
      [working_line(tick, trace)]
    end
  end

  @spec wonder_picker_lines(map(), map() | nil) :: [String.t()]
  def wonder_picker_lines(detection, nav), do: WonderPicker.lines(detection, nav)

  @spec interview_reasoning_lines(map(), integer() | nil) :: [String.t()]
  def interview_reasoning_lines(result, tick \\ nil) do
    case interview_state(result) do
      %{} = iv ->
        Status.reasoning_lines(iv, tick, paused?(result))

      _none ->
        []
    end
  end

  @spec mcp_activity_lines(map()) :: [String.t()]
  def mcp_activity_lines(result) do
    case interview_state(result) do
      %{mcp_activity: lines} -> Status.mcp_activity_lines(lines)
      _none -> []
    end
  end

  @spec interview_block_lines(map(), map() | nil, integer()) ::
          {String.t(), [String.t() | {String.t(), atom()} | :rule], String.t()} | nil
  def interview_block_lines(result, nav, tick) do
    cond do
      detection = wonder_detection(result) ->
        wonder_picker_block(result, detection, nav, tick)

      interview_state(result) ->
        lines = interview_state_rows(result, tick)
        paused? = paused?(result)

        {Hints.marker(paused?), lines,
         Hints.wonder_hint(paused?, not is_nil(wonder_detection(result)))}

      session = interview_session(result) ->
        label = Map.get(session, :label, "ooo interview")
        paused? = paused?(result)
        spinner = if paused?, do: [], else: [{working_line(tick, nil), :dim}]
        {Hints.marker(paused?), [label | spinner], Hints.session_hint(paused?)}

      true ->
        nil
    end
  rescue
    _exception -> nil
  end

  defp wonder_picker_block(result, detection, nav, tick) do
    case wonder_picker_lines(detection, nav) do
      [] ->
        fallback_interview_block(result, tick)

      picker ->
        paused? = paused?(result)

        {Hints.marker(paused?), picker,
         Hints.wonder_pick_hint(paused?, question_count(detection))}
    end
  end

  defp fallback_interview_block(result, tick) do
    case interview_state(result) do
      nil ->
        nil

      _interview ->
        paused? = paused?(result)

        {Hints.marker(paused?), interview_state_rows(result, tick),
         Hints.wonder_hint(paused?, false)}
    end
  end

  defp interview_state_rows(result, tick) do
    result
    |> dialogue_rows(false)
    |> prepend_current_question(result)
    |> Kernel.++(interview_status_rows(result, tick))
  end

  defp prepend_current_question(rows, result) do
    question =
      result
      |> interview_state()
      |> case do
        %{} = iv -> Map.get(iv, :question) || Map.get(iv, "question")
        _none -> nil
      end
      |> plain_line()

    if question == "" or Enum.any?(rows, &line_contains?(&1, question)) do
      rows
    else
      [{question, :warn} | rows]
    end
  end

  defp line_contains?({text, _style}, needle) when is_binary(text),
    do: String.contains?(text, needle)

  defp line_contains?(text, needle) when is_binary(text), do: String.contains?(text, needle)
  defp line_contains?(_line, _needle), do: false

  @spec default_nav(map(), map() | nil) :: map()
  def default_nav(detection, current_nav), do: WonderPicker.default_nav(detection, current_nav)

  @spec question_count(map()) :: non_neg_integer()
  def question_count(detection), do: WonderPicker.question_count(detection)

  @spec wonder_questions(map()) :: [map()]
  def wonder_questions(detection), do: WonderPicker.questions(detection)

  @spec nav_qidx(map() | nil) :: integer()
  def nav_qidx(nav), do: WonderPicker.nav_qidx(nav)

  @spec nav_cursor(map() | nil, integer()) :: integer()
  def nav_cursor(nav, qi), do: WonderPicker.nav_cursor(nav, qi)

  @spec nav_pick(map() | nil, integer()) :: integer()
  def nav_pick(nav, qi), do: WonderPicker.nav_pick(nav, qi)

  @spec nav_multi_pick(map() | nil, integer()) :: MapSet.t()
  def nav_multi_pick(nav, qi), do: WonderPicker.nav_multi_pick(nav, qi)

  @spec multi_select?(map()) :: boolean()
  def multi_select?(question), do: WonderPicker.multi_select?(question)

  @spec md_text(term()) :: String.t()
  def md_text(text), do: Text.md_text(text)

  @spec flatten_line(term()) :: String.t()
  def flatten_line(text), do: Text.flatten_line(text)

  @spec working_line(integer(), term()) :: String.t()
  def working_line(tick, trace) do
    Status.working_line(tick, trace)
  end

  @spec spin(integer() | term()) :: String.t()
  def spin(tick), do: Status.spin(tick)

  defp interview_status_rows(result, tick) do
    status = interview_working_lines(result, tick)

    cond do
      status == [] ->
        []

      dialogue_rows(result, false) == [] ->
        Enum.map(status, &{&1, :dim})

      true ->
        [:rule | Enum.map(status, &{&1, :dim})]
    end
  end

  @spec plain_line(term()) :: String.t()
  def plain_line(text), do: Text.plain_line(text)

  defp interview_state(result) do
    InterviewLiveState.interview(result)
  end

  defp wonder_detection(result) do
    InterviewLiveState.wonder_tool(result)
  end

  defp interview_session(result) do
    InterviewLiveState.interview_session(result)
  end

  defp paused?(result) do
    InterviewLiveState.paused?(result)
  end
end
