defmodule Ourocode.Runtime.LoopBindingRouterDecision do
  @moduledoc """
  Converts question-router results into interview-loop actions.
  """

  alias Ourocode.Runtime.{InterviewState, LoopBindingInterviewText}

  @type action ::
          {:followup, String.t(), non_neg_integer(), String.t()}
          | {:ask_user, String.t(), [term()], :router | :leaked_prompt}
          | {:error, term()}

  @spec action(term(), String.t(), non_neg_integer()) :: action()
  def action({:answer, payload_text, source}, question, streak)
      when is_binary(question) and is_integer(streak) do
    if InterviewState.leaked_router_prompt?(payload_text) do
      {:ask_user, question, [], :leaked_prompt}
    else
      dialogue_text = InterviewState.ensure_answer_prefix(payload_text, source)
      next_streak = LoopBindingInterviewText.streak_after(streak, source)
      {:followup, payload_text, next_streak, dialogue_text}
    end
  end

  def action({:ask_user, prompt, options}, _question, _streak) do
    {:ask_user, prompt, options, :router}
  end

  def action({:error, reason}, _question, _streak), do: {:error, reason}
end
