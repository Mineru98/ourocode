defmodule Ourocode.Runtime.OuroborosSessionRounds do
  @moduledoc """
  Summarizes persisted interview rounds for session reasoning projections.
  """

  alias Ourocode.Runtime.InterviewReasoningLine

  @type summary :: %{
          answered_rounds: non_neg_integer(),
          total_rounds: non_neg_integer(),
          pending_question?: boolean(),
          last_question: String.t() | nil
        }

  @spec summarize(term()) :: summary()
  def summarize(rounds) when is_list(rounds) do
    %{
      answered_rounds: Enum.count(rounds, &answered?/1),
      total_rounds: length(rounds),
      pending_question?: pending_question?(rounds),
      last_question: last_question(rounds)
    }
  end

  def summarize(_rounds) do
    %{
      answered_rounds: 0,
      total_rounds: 0,
      pending_question?: false,
      last_question: nil
    }
  end

  defp answered?(%{} = round) do
    case InterviewReasoningLine.value(round, "user_response") do
      response when is_binary(response) -> String.trim(response) != ""
      nil -> false
      _other -> true
    end
  end

  defp answered?(_round), do: false

  defp pending_question?([]), do: false

  defp pending_question?(rounds) do
    rounds
    |> List.last()
    |> case do
      %{} = round -> not answered?(round)
      _other -> false
    end
  end

  defp last_question([]), do: nil

  defp last_question(rounds) do
    rounds
    |> List.last()
    |> case do
      %{} = round -> InterviewReasoningLine.value(round, "question")
      _other -> nil
    end
  end
end
