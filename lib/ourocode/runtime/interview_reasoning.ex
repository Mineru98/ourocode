defmodule Ourocode.Runtime.InterviewReasoning do
  @moduledoc """
  Formats interview metadata into compact right-panel reasoning lines.
  """

  alias Ourocode.Runtime.{InterviewMeta, InterviewReasoningLine}

  @spec lines(map()) :: [String.t()]
  def lines(meta) when is_map(meta) do
    [
      meta_value(meta, "internal_reasoning"),
      meta_value(meta, "mcp_reasoning"),
      meta_value(meta, "reasoning"),
      meta_value(meta, "interview_reasoning")
    ]
    |> Enum.find_value([], fn value ->
      case normalize_lines(value) do
        [] -> nil
        lines -> lines
      end
    end)
  end

  def lines(_meta), do: []

  defp normalize_lines(lines) when is_list(lines) do
    lines
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(12)
  end

  defp normalize_lines(line) when is_binary(line) do
    line
    |> String.split(~r/\r?\n/)
    |> normalize_lines()
  end

  defp normalize_lines(%{} = state) do
    [
      InterviewReasoningLine.state_line(state, "phase", "phase"),
      InterviewReasoningLine.state_line(state, "session_id", "session"),
      InterviewReasoningLine.rounds_line(state),
      InterviewReasoningLine.state_line(state, "pending_question", "pending"),
      InterviewReasoningLine.state_line(state, "is_brownfield", "brownfield"),
      InterviewReasoningLine.state_line(state, "ambiguity_score", "ambiguity"),
      InterviewReasoningLine.state_line(state, "milestone", "milestone"),
      InterviewReasoningLine.state_line(state, "seed_ready", "seed-ready"),
      InterviewReasoningLine.state_line(state, "completion_qualified", "completion-qualified"),
      InterviewReasoningLine.completion_blockers_line(state),
      InterviewReasoningLine.stability_line(state),
      InterviewReasoningLine.state_line(state, "recoverable", "recoverable"),
      InterviewReasoningLine.state_line(state, "question_chars", "question_chars"),
      InterviewReasoningLine.state_line(state, "next_action", "next")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(12)
  end

  defp normalize_lines(_value), do: []

  defp meta_value(meta, key) when is_map(meta) do
    InterviewMeta.value(meta, key)
  end

  defp meta_value(_meta, _key), do: nil
end
