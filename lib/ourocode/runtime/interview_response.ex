defmodule Ourocode.Runtime.InterviewResponse do
  @moduledoc """
  Pure parsing helpers for Ouroboros interview MCP responses.
  """

  alias Ourocode.MCP.ParentCallResult

  # Ouroboros writes the session id as `Session ID: <id>` (start),
  # `session_id="<id>"` (resume hint), or bare `Session <id>` (resume).
  @session_id_re ~r/(?:session[_\s]?id)\s*[=:]\s*"?([A-Za-z0-9_\-\.]+)"?|(?<![A-Za-z])Session\s+([A-Za-z][\w\-\.]+)/i
  @ambiguity_re ~r/\(ambiguity:\s*([0-9]*\.?[0-9]+)\)\s*(.*)/s

  @spec parent_response(term()) :: map()
  def parent_response(%ParentCallResult{response: response}) when is_map(response), do: response
  def parent_response(%{response: response}) when is_map(response), do: response
  def parent_response(%{"response" => response}) when is_map(response), do: response
  def parent_response(_result), do: %{}

  @spec text(map()) :: String.t()
  def text(%{"result" => %{"content" => content}}) when is_list(content) do
    content
    |> Enum.map(fn part -> (is_map(part) && (part["text"] || part[:text])) || nil end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  def text(%{"result" => %{"content" => text}}) when is_binary(text), do: text
  def text(_response), do: ""

  @spec meta(map()) :: map()
  def meta(response) when is_map(response) do
    result = if is_map(response["result"]), do: response["result"], else: %{}
    structured = structured_content(result)

    [
      result["meta"],
      result["_meta"],
      structured["meta"],
      structured["_meta"],
      structured,
      content_meta(result),
      response |> text() |> decode_text_meta()
    ]
    |> merge_meta_candidates()
  end

  def meta(_response), do: %{}

  @spec extract_session_id(String.t(), map()) :: String.t() | nil
  def extract_session_id(text, meta) do
    case meta_value(meta, "session_id") do
      id when is_binary(id) and id != "" ->
        id

      _none ->
        case Regex.run(@session_id_re, text || "") do
          [_, id] when is_binary(id) and id != "" -> id
          [_, "", id] when is_binary(id) and id != "" -> id
          _no_match -> nil
        end
    end
  end

  @spec question_from(term()) :: String.t()
  def question_from(text) do
    case parse_ambiguity(text) do
      {:ok, _score, question} -> clean_markdown(question)
      :none -> text |> strip_interview_preamble() |> clean_markdown()
    end
  end

  @spec interview_text(map()) :: String.t()
  def interview_text(event) when is_map(event) do
    payload = if is_map(event[:payload]), do: event[:payload], else: %{}
    result = if is_map(payload["result"]), do: payload["result"], else: %{}

    [
      event[:token],
      event[:content],
      event[:text],
      event[:question],
      payload[:token],
      payload["token"],
      payload[:content],
      payload["content"],
      payload[:text],
      payload["text"],
      payload[:question],
      payload["question"],
      text(%{"result" => result})
    ]
    |> Enum.find("", &(is_binary(&1) and &1 != ""))
  end

  def interview_text(_event), do: ""

  @spec interview_meta(map()) :: map()
  def interview_meta(event) when is_map(event) do
    payload = if is_map(event[:payload]), do: event[:payload], else: %{}
    result = if is_map(payload["result"]), do: payload["result"], else: %{}
    structured = structured_content(result)

    [
      event[:meta],
      event["meta"],
      event[:_meta],
      event["_meta"],
      payload[:meta],
      payload["meta"],
      payload[:_meta],
      payload["_meta"],
      result["meta"],
      result["_meta"],
      structured["meta"],
      structured["_meta"],
      structured,
      content_meta(result)
    ]
    |> merge_meta_candidates()
  end

  def interview_meta(_event), do: %{}

  @spec numeric_meta_value(map(), String.t()) :: float() | nil
  def numeric_meta_value(meta, key) do
    case meta_value(meta, key) do
      value when is_float(value) -> value
      value when is_integer(value) -> value / 1
      value when is_binary(value) -> parse_float(value)
      _other -> nil
    end
  end

  @spec reasoning_lines(map()) :: [String.t()]
  def reasoning_lines(meta) when is_map(meta) do
    [
      meta_value(meta, "internal_reasoning"),
      meta_value(meta, "mcp_reasoning"),
      meta_value(meta, "reasoning"),
      meta_value(meta, "interview_reasoning")
    ]
    |> Enum.find_value([], fn value ->
      case normalize_reasoning_lines(value) do
        [] -> nil
        lines -> lines
      end
    end)
  end

  def reasoning_lines(_meta), do: []

  @spec meta_value(map(), String.t()) :: term()
  def meta_value(meta, key) when is_map(meta) do
    case Map.fetch(meta, key) do
      {:ok, value} -> value
      :error -> Map.get(meta, safe_atom(key))
    end
  end

  def meta_value(_meta, _key), do: nil

  @spec parse_ambiguity(term()) :: {:ok, float() | nil, String.t()} | :none
  def parse_ambiguity(text) when is_binary(text) do
    case Regex.run(@ambiguity_re, text) do
      [_, score, question] ->
        {:ok, parse_float(score), String.trim(question)}

      _no_match ->
        :none
    end
  end

  def parse_ambiguity(_text), do: :none

  @spec clean_markdown(term()) :: String.t()
  def clean_markdown(text) when is_binary(text) do
    text
    |> String.replace(~r/(\*\*|__)(.*?)\1/s, "\\2")
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/^\s{0,3}\#{1,6}\s+/m, "")
    |> String.trim()
  end

  def clean_markdown(text), do: to_string(text)

  defp strip_interview_preamble(text) when is_binary(text) do
    text
    |> String.replace(~r/\A\s*Interview started\.\s*Session ID:\s*\S+\s*/i, "")
    |> String.replace(~r/\A\s*Session ID:\s*\S+\s*/i, "")
    |> String.trim()
  end

  defp strip_interview_preamble(text), do: to_string(text || "")

  defp normalize_reasoning_lines(lines) when is_list(lines) do
    lines
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(12)
  end

  defp normalize_reasoning_lines(line) when is_binary(line) do
    line
    |> String.split(~r/\r?\n/)
    |> normalize_reasoning_lines()
  end

  defp normalize_reasoning_lines(%{} = state) do
    [
      state_line(state, "phase", "phase"),
      state_line(state, "session_id", "session"),
      rounds_line(state),
      state_line(state, "pending_question", "pending"),
      state_line(state, "is_brownfield", "brownfield"),
      state_line(state, "ambiguity_score", "ambiguity"),
      state_line(state, "milestone", "milestone"),
      state_line(state, "seed_ready", "seed-ready"),
      state_line(state, "completion_qualified", "completion-qualified"),
      completion_blockers_line(state),
      stability_line(state),
      state_line(state, "recoverable", "recoverable"),
      state_line(state, "question_chars", "question_chars"),
      state_line(state, "next_action", "next")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(12)
  end

  defp normalize_reasoning_lines(_value), do: []

  defp structured_content(%{"structuredContent" => value}) when is_map(value), do: value
  defp structured_content(%{"structured_content" => value}) when is_map(value), do: value
  defp structured_content(_result), do: %{}

  defp content_meta(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find_value(%{}, fn
      %{"meta" => meta} when is_map(meta) -> meta
      %{"_meta" => meta} when is_map(meta) -> meta
      %{"annotations" => %{"meta" => meta}} when is_map(meta) -> meta
      %{meta: meta} when is_map(meta) -> meta
      %{_meta: meta} when is_map(meta) -> meta
      _part -> nil
    end)
  end

  defp content_meta(_result), do: %{}

  defp merge_meta_candidates(candidates) do
    candidates
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&(&1 == %{}))
    |> Enum.reduce(%{}, fn candidate, acc -> Map.merge(acc, candidate) end)
  end

  defp state_line(state, key, label) do
    case meta_value(state, key) do
      value when value in [nil, "", []] -> nil
      true when key == "pending_question" -> "#{label}: waiting for user answer"
      false when key == "pending_question" -> nil
      value -> "#{label}: #{format_reasoning_value(value)}"
    end
  end

  defp rounds_line(state) do
    answered = meta_value(state, "answered_rounds")
    total = meta_value(state, "total_rounds")

    if is_nil(answered) or is_nil(total),
      do: nil,
      else: "rounds: #{answered} answered / #{total} total"
  end

  defp completion_blockers_line(state) do
    case meta_value(state, "completion_floor_failures") do
      failures when is_list(failures) and failures != [] ->
        "completion blocked: " <> Enum.map_join(failures, "; ", &format_reasoning_value/1)

      _other ->
        nil
    end
  end

  defp stability_line(state) do
    streak = meta_value(state, "completion_candidate_streak")
    required = meta_value(state, "streak_required")

    cond do
      is_nil(streak) -> nil
      is_nil(required) -> "stability: #{streak}"
      true -> "stability: #{streak}/#{required}"
    end
  end

  defp format_reasoning_value(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp format_reasoning_value(value) when is_binary(value), do: value
  defp format_reasoning_value(value), do: to_string(value)

  defp decode_text_meta(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      case Ourocode.Json.decode(trimmed) do
        {:ok, %{} = body} -> body
        _error -> %{}
      end
    else
      %{}
    end
  end

  defp decode_text_meta(_text), do: %{}

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> nil
    end
  end
end
