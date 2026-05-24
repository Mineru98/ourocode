defmodule Ourocode.Runtime.ActivityLine do
  @moduledoc """
  Pure transformations for live Ouroboros activity lines.

  `ActivitySnapshot` owns state refresh. This module owns the text-level
  enrichment and duplicate suppression used before activity is rendered.
  """

  @spec enrich(term(), map()) :: term()
  def enrich(line, %{initial_context: initial_context} = activity_context)
      when is_binary(line) and is_binary(initial_context) do
    cond do
      String.contains?(line, " · initial: ") ->
        line

      String.contains?(line, "interview started") ->
        line
        |> String.replace(~r/\s*·\s*\d+\s+chars/u, "")
        |> Kernel.<>(" · initial: #{initial_context}")

      true ->
        enrich_question(line, activity_context)
    end
  end

  def enrich(line, activity_context) when is_binary(line) do
    enrich_question(line, activity_context)
  end

  def enrich(line, _activity_context), do: line

  @spec dedupe([term()]) :: [term()]
  def dedupe(lines) when is_list(lines) do
    lines
    |> Enum.reverse()
    |> Enum.uniq_by(&dedupe_key/1)
    |> Enum.reverse()
  end

  defp enrich_question(line, %{questions: questions}) when is_map(questions) do
    cond do
      String.contains?(line, " · question: ") ->
        line

      true ->
        case Regex.run(~r/\bround\s+(\d+)\s+·\s+question generated\b/u, line) do
          [_match, round] -> question_line(line, questions, round)
          _no_match -> line
        end
    end
  end

  defp enrich_question(line, _activity_context), do: line

  defp question_line(line, questions, round) do
    case Integer.parse(round) do
      {round_number, ""} ->
        case Map.get(questions, round_number) do
          question when is_binary(question) and question != "" ->
            "round #{round_number} · question: #{question}"

          _none ->
            line
        end

      _error ->
        line
    end
  end

  defp dedupe_key(line) when is_binary(line) do
    line
    |> String.replace(~r/^activity:\s*/u, "")
    |> String.replace(~r/\s*·\s*\d+\s+chars/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp dedupe_key(line), do: line
end
