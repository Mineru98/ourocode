defmodule Ourocode.Runtime.InterviewResponse do
  @moduledoc """
  Pure parsing helpers for Ouroboros interview MCP responses.
  """

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.Runtime.InterviewMeta
  alias Ourocode.Runtime.InterviewReasoning

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
    InterviewMeta.response_meta(response, text(response))
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
    InterviewMeta.event_meta(event)
  end

  def interview_meta(_event), do: %{}

  @spec numeric_meta_value(map(), String.t()) :: float() | nil
  def numeric_meta_value(meta, key) do
    InterviewMeta.numeric_value(meta, key)
  end

  @spec reasoning_lines(map()) :: [String.t()]
  def reasoning_lines(meta), do: InterviewReasoning.lines(meta)

  @spec meta_value(map(), String.t()) :: term()
  def meta_value(meta, key) when is_map(meta) do
    InterviewMeta.value(meta, key)
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

  defp parse_float(value) do
    case Float.parse(value) do
      {f, _rest} -> f
      :error -> nil
    end
  end
end
