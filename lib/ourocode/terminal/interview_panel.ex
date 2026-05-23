defmodule Ourocode.Terminal.InterviewPanel do
  @moduledoc """
  Pure text rendering helpers for interview, wonderTool, and MCP activity panes.
  """

  @dialogue_tail 6
  @spin ["|", "/", "-", "\\"]

  @spec dialogue_rows(map(), boolean()) :: [{String.t(), atom()} | :rule]
  def dialogue_rows(result, drop_trailing_mcp?) do
    turns =
      result
      |> interview_state()
      |> then(&((&1 && Map.get(&1, :dialogue, [])) || []))
      |> Enum.reverse()

    turns =
      if drop_trailing_mcp? do
        case List.last(turns) do
          %{role: :mcp} -> Enum.drop(turns, -1)
          _other -> turns
        end
      else
        turns
      end

    turns
    |> Enum.take(-@dialogue_tail)
    |> Enum.reject(&internal_dialogue_turn?/1)
    |> Enum.map(&dialogue_row/1)
    |> Enum.intersperse(:rule)
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
  def wonder_picker_lines(detection, nav) do
    questions = wonder_questions(detection)
    n = length(questions)

    cond do
      n == 0 ->
        []

      Map.get(nav || %{}, :review?, false) ->
        wonder_review_lines(questions, nav)

      true ->
        qi = clamp_index(nav_qidx(nav), n)
        q = Enum.at(questions, qi)
        cursor = if multi_select?(q), do: nav_cursor(nav, qi), else: nav_pick(nav, qi)
        wonder_block_lines(q, qi, n, cursor, nav_multi_pick(nav, qi))
    end
  end

  @spec interview_reasoning_lines(map(), integer() | nil) :: [String.t()]
  def interview_reasoning_lines(result, tick \\ nil) do
    case interview_state(result) do
      %{} = iv ->
        [
          status_line(iv, tick, paused?(result)),
          mcp_reasoning_lines(iv),
          fallback_reasoning_lines(iv),
          complete_line(iv)
        ]
        |> List.flatten()
        |> Enum.reject(&is_nil/1)

      _none ->
        []
    end
  end

  @spec mcp_activity_lines(map()) :: [String.t()]
  def mcp_activity_lines(result) do
    case interview_state(result) do
      %{mcp_activity: lines} when is_list(lines) -> format_mcp_activity_lines(lines)
      _none -> []
    end
  end

  @spec default_nav(map(), map() | nil) :: map()
  def default_nav(detection, current_nav) do
    req_id = wonder_req_id(detection)

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
  def question_count(detection), do: detection |> wonder_questions() |> length()

  @spec wonder_questions(map()) :: [map()]
  def wonder_questions(detection) do
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

  @spec md_text(term()) :: String.t()
  def md_text(text) do
    text
    |> to_string()
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/(\*|_)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.replace(~r/\[([^\]]+)\]\([^)]+\)/, "\\1")
    |> strip_unstable_glyphs()
    |> String.trim()
  end

  @spec flatten_line(term()) :: String.t()
  def flatten_line(text) do
    text
    |> md_text()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @spec working_line(integer(), term()) :: String.t()
  def working_line(tick, trace) do
    phase =
      if is_binary(trace) and trace != "",
        do: router_trace_label(trace),
        else: "thinking — the main session is handling this"

    spin(tick) <> " " <> phase
  end

  @spec spin(integer() | term()) :: String.t()
  def spin(tick) when is_integer(tick), do: Enum.at(@spin, rem(tick, length(@spin)))
  def spin(_tick), do: "·  "

  defp internal_dialogue_turn?(%{role: :main, text: text}) when is_binary(text),
    do: leaked_router_prompt?(text)

  defp internal_dialogue_turn?(_turn), do: false

  defp dialogue_row(%{role: role, text: text}) do
    {label, style} =
      case role do
        :mcp -> {"MCP ", :warn}
        :main -> {"MAIN", :ok}
        :user -> {"YOU ", :strong}
      end

    {label <> "  " <> flatten_line(text), style}
  end

  defp leaked_router_prompt?(text) when is_binary(text) do
    flat = String.replace(text, ~r/\s+/, " ")

    String.contains?(flat, [
      "You are the answerer/router half",
      "Routing rules (from the interview SKILL)",
      "Tool protocol",
      "Output exactly one directive as the first line",
      "ANSWER [from-code] <answer>",
      "ASK_USER <question for the human>"
    ]) or
      (String.length(flat) > 900 and
         String.contains?(flat, "ANSWER [from-code]") and
         String.contains?(flat, "ASK_USER"))
  end

  defp leaked_router_prompt?(_text), do: false

  defp router_trace_label(trace) do
    clean = flatten_line(trace)
    upcased = String.upcase(clean)

    cond do
      String.starts_with?(upcased, "ASK_USER") ->
        "question ready — choose or type an answer in the interview block"

      answer = Regex.run(~r/^ANSWER(?:\s+\[[^\]]+\])?:\s*(.+)$/i, clean) ->
        "main session answered: " <> Enum.at(answer, 1)

      String.starts_with?(upcased, "ANSWER") ->
        "main session answered from context"

      String.starts_with?(upcased, "TOOL") ->
        "main session is checking project context"

      String.starts_with?(upcased, "PATH") ->
        "main session is choosing the next interview step"

      true ->
        clean
    end
  end

  defp wonder_review_lines(questions, nav) do
    total = length(questions)

    review_rows =
      questions
      |> Enum.with_index()
      |> Enum.flat_map(fn {q, qi} ->
        answer = review_answer_label(q, nav, qi)
        ["[#{qi + 1}/#{total}] #{md_text(Map.get(q, :header, "Question"))}", "  #{answer}"]
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
      %{} = opt -> md_text(Map.get(opt, :label, "Option #{index + 1}"))
      _none -> "Free answer"
    end
  end

  defp wonder_block_lines(q, qi, n, cursor, multi_picks) do
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
        do: "Question #{qi + 1}/#{n}#{progress}  ·  #{md_text(Map.get(q, :header, ""))}",
        else: md_text(Map.get(q, :header, ""))

    opt_lines =
      q
      |> Map.get(:options, [])
      |> Enum.with_index()
      |> Enum.map(fn {opt, oi} ->
        row_cursor = if oi == cursor, do: ">", else: " "
        label = md_text(Map.get(opt, :label, ""))
        desc = md_text(Map.get(opt, :description, ""))

        marker =
          if multi_select?(q),
            do: "#{if(MapSet.member?(multi_picks, oi), do: "[x]", else: "[ ]")} [#{oi + 1}]",
            else: "[#{oi + 1}]"

        "#{row_cursor}#{row_cursor} #{marker} #{label} - #{desc}"
      end)

    free_row_cursor = if cursor == length(opt_lines), do: ">", else: " "
    free_row = "#{free_row_cursor}#{free_row_cursor} [Free answer] type below, then Enter"

    [header, md_text(Map.get(q, :question, "")) | opt_lines ++ [free_row]]
  end

  defp wonder_req_id(detection) do
    case Map.get(detection, :request_id) do
      id when is_binary(id) and id != "" -> id
      _none -> "wt-" <> Integer.to_string(:erlang.phash2(wonder_questions(detection)))
    end
  end

  defp default_picks(detection) do
    detection
    |> wonder_questions()
    |> Enum.with_index()
    |> Map.new(fn {q, qi} ->
      opts = Map.get(q, :options, [])
      idx = Enum.find_index(opts, &Map.get(&1, :recommended?, false)) || 0
      if multi_select?(q), do: {qi, MapSet.new([idx])}, else: {qi, idx}
    end)
  end

  defp default_cursors(detection) do
    detection
    |> wonder_questions()
    |> Enum.with_index()
    |> Enum.filter(fn {q, _qi} -> multi_select?(q) end)
    |> Map.new(fn {_q, qi} -> {qi, 0} end)
  end

  defp mcp_reasoning_lines(%{mcp_reasoning: lines}) when is_list(lines) do
    lines
    |> Enum.map(&flatten_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp mcp_reasoning_lines(_iv), do: []

  defp format_mcp_activity_lines(lines) do
    lines
    |> Enum.take(-80)
    |> Enum.map(&activity_display_line/1)
    |> Enum.reject(&(&1 == "activity: "))
  end

  defp activity_display_line(line) do
    line = plain_line(line)

    if String.starts_with?(line, "activity: "),
      do: line,
      else: "activity: " <> line
  end

  @spec plain_line(term()) :: String.t()
  def plain_line(text) do
    text
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp fallback_reasoning_lines(%{mcp_reasoning: lines}) when is_list(lines) and lines != [],
    do: []

  defp fallback_reasoning_lines(iv) do
    [
      session_line(iv),
      ambiguity_line(iv),
      milestone_line(iv),
      seed_ready_line(iv)
    ] ++ breakdown_lines(iv)
  end

  defp status_line(_iv, _tick, true), do: "phase paused - discussing with main session"

  defp status_line(%{waiting: true, status: s}, tick, false) when is_binary(s) and s != "" do
    label =
      case String.downcase(s) do
        "waiting for mcp interview question" ->
          "phase received - MCP is preparing the interview question"

        "waiting for mcp follow-up question" ->
          "phase routing - MCP is preparing the next question"

        "waiting for your answer" ->
          "phase waiting - waiting for your answer"

        _other ->
          s
      end

    if is_integer(tick), do: spin(tick) <> " " <> label, else: label
  end

  defp status_line(%{status: s}, _tick, _paused) when is_binary(s) and s != "",
    do: "phase active - " <> s

  defp status_line(_iv, _tick, _paused), do: nil

  defp session_line(%{session_id: s}) when is_binary(s) and s != "",
    do: "session " <> s

  defp session_line(_iv), do: nil

  defp ambiguity_line(%{ambiguity: a}) when is_float(a) or is_integer(a),
    do: "ambiguity #{:erlang.float_to_binary(a / 1, decimals: 2)}"

  defp ambiguity_line(_iv), do: nil

  defp milestone_line(%{milestone: m}) when is_binary(m) and m != "", do: "milestone " <> m
  defp milestone_line(_iv), do: nil

  defp seed_ready_line(%{seed_ready: true}), do: "seed-ready: yes"
  defp seed_ready_line(%{seed_ready: false}), do: "seed-ready: no"
  defp seed_ready_line(_iv), do: nil

  defp breakdown_lines(%{breakdown: b}) when is_map(b) do
    Enum.map(b, fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end

  defp breakdown_lines(_iv), do: []

  defp complete_line(%{complete: reason}) when not is_nil(reason),
    do: "interview complete: #{reason}"

  defp complete_line(_iv), do: nil

  defp interview_state(result) do
    result
    |> live_result()
    |> Map.get(:interview)
  end

  defp paused?(result) do
    result
    |> live_result()
    |> Map.get(:paused, false)
  end

  defp live_result(%{pane_snapshot: snapshot} = result) when is_function(snapshot, 0) do
    case snapshot.() do
      %{} = live -> Map.merge(result, live)
      _other -> result
    end
  rescue
    _exception -> result
  end

  defp live_result(result), do: result

  defp clamp_index(_i, 0), do: 0
  defp clamp_index(i, n), do: Integer.mod(i, n)

  defp strip_unstable_glyphs(text) do
    text
    |> String.replace(~r/[\x{FFFD}\x{FE0E}\x{FE0F}\x{200D}]/u, "")
    |> String.replace(~r/[\x{1F000}-\x{1FAFF}]/u, "")
    |> String.replace(~r/\s+/, " ")
  end
end
