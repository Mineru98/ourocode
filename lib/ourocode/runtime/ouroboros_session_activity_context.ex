defmodule Ourocode.Runtime.OuroborosSessionActivityContext do
  @moduledoc """
  Projects persisted interview session state into activity enrichment context.
  """

  alias Ourocode.Runtime.InterviewMeta

  @spec build(map()) :: map()
  def build(state) when state == %{}, do: %{}

  def build(%{} = state) do
    rounds = value(state, "rounds") || []

    %{
      session_id: value(state, "interview_id"),
      initial_context: preview(value(state, "initial_context")),
      questions: question_previews(rounds)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  defp question_previews(rounds) when is_list(rounds) do
    rounds
    |> Enum.reduce(%{}, fn
      %{} = round, acc ->
        round_number = value(round, "round_number")
        question = preview(value(round, "question"))

        if is_integer(round_number) and is_binary(question) and question != "",
          do: Map.put(acc, round_number, question),
          else: acc

      _round, acc ->
        acc
    end)
  end

  defp question_previews(_rounds), do: %{}

  defp preview(text) when is_binary(text) do
    text
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(96)
  end

  defp preview(_text), do: nil

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> String.slice(0, max)
    |> String.trim()
    |> Kernel.<>("...")
  end

  defp value(map, key), do: InterviewMeta.value(map, key)
end
