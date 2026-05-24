defmodule Ourocode.Runtime.OuroborosSessionProjection do
  @moduledoc """
  Pure projections from persisted Ouroboros interview session state.
  """

  alias Ourocode.Runtime.{
    InterviewReasoningLine,
    OuroborosSessionActivityContext,
    OuroborosSessionRounds,
    OuroborosSessionStatus
  }

  @max_lines 12

  @spec reasoning(map(), String.t()) :: {[String.t()], map()}
  def reasoning(state, _fallback_session_id) when state == %{}, do: {[], %{}}

  def reasoning(%{} = state, fallback_session_id) do
    rounds = InterviewReasoningLine.value(state, "rounds") || []
    rounds_summary = OuroborosSessionRounds.summarize(rounds)
    status = InterviewReasoningLine.value(state, "status")

    reasoning_state =
      %{
        "phase" => OuroborosSessionStatus.phase(status, rounds_summary),
        "next_action" => OuroborosSessionStatus.next_action(status, rounds_summary),
        "session_id" =>
          InterviewReasoningLine.value(state, "interview_id") || fallback_session_id,
        "answered_rounds" => rounds_summary.answered_rounds,
        "total_rounds" => rounds_summary.total_rounds,
        "pending_question" => rounds_summary.pending_question?,
        "is_brownfield" => InterviewReasoningLine.value(state, "is_brownfield"),
        "ambiguity_score" => InterviewReasoningLine.value(state, "ambiguity_score"),
        "ambiguity_breakdown" => InterviewReasoningLine.value(state, "ambiguity_breakdown"),
        "seed_ready" =>
          OuroborosSessionStatus.seed_ready?(
            status,
            InterviewReasoningLine.value(state, "seed_ready")
          ),
        "completion_candidate_streak" =>
          InterviewReasoningLine.value(state, "completion_candidate_streak"),
        "status" => status,
        "question_chars" => question_chars(rounds_summary.last_question),
        "source" => "session_state"
      }
      |> reject_nil_values()

    {lines_from_state(reasoning_state), reasoning_state}
  end

  @spec activity_context(map()) :: map()
  def activity_context(state), do: OuroborosSessionActivityContext.build(state)

  defp question_chars(question) when is_binary(question), do: String.length(question)
  defp question_chars(_question), do: nil

  defp lines_from_state(state) do
    [
      InterviewReasoningLine.state_line(state, "phase", "phase"),
      InterviewReasoningLine.state_line(state, "session_id", "session"),
      InterviewReasoningLine.rounds_line(state),
      InterviewReasoningLine.state_line(state, "pending_question", "pending"),
      InterviewReasoningLine.state_line(state, "is_brownfield", "brownfield"),
      InterviewReasoningLine.state_line(state, "ambiguity_score", "ambiguity"),
      InterviewReasoningLine.state_line(state, "seed_ready", "seed-ready"),
      InterviewReasoningLine.stability_line(state),
      InterviewReasoningLine.state_line(state, "status", "status"),
      InterviewReasoningLine.state_line(state, "question_chars", "question_chars"),
      InterviewReasoningLine.state_line(state, "next_action", "next"),
      InterviewReasoningLine.state_line(state, "source", "source")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(@max_lines)
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, "", []] end)
  end
end
