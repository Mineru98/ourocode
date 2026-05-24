defmodule Ourocode.Runtime.OuroborosSessionStatus do
  @moduledoc """
  Interprets persisted interview session status for reasoning projections.
  """

  @type rounds_summary :: %{
          required(:answered_rounds) => non_neg_integer(),
          required(:total_rounds) => non_neg_integer(),
          required(:pending_question?) => boolean()
        }

  @spec phase(String.t() | nil, rounds_summary()) :: String.t()
  def phase("completed", _summary), do: "complete"
  def phase("failed", _summary), do: "failed"
  def phase(_status, %{pending_question?: true}), do: "question"
  def phase(_status, %{answered_rounds: 0, total_rounds: 0}), do: "start"

  def phase(_status, %{answered_rounds: answered, total_rounds: total}) when answered >= total,
    do: "answer"

  def phase(_status, _summary), do: "in_progress"

  @spec next_action(String.t() | nil, rounds_summary()) :: String.t()
  def next_action("completed", _summary), do: "generate seed or run next step"
  def next_action("failed", _summary), do: "inspect failure and retry"
  def next_action(_status, %{pending_question?: true}), do: "ask user to answer pending question"
  def next_action(_status, _summary), do: "wait for next interview question"

  @spec seed_ready?(String.t() | nil, term()) :: term()
  def seed_ready?("completed", _seed_ready), do: true
  def seed_ready?(_status, seed_ready), do: seed_ready
end
