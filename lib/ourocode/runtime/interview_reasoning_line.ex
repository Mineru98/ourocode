defmodule Ourocode.Runtime.InterviewReasoningLine do
  @moduledoc """
  Shared formatting helpers for compact interview reasoning lines.
  """

  alias Ourocode.Runtime.InterviewMeta

  @spec state_line(map(), String.t(), String.t()) :: String.t() | nil
  def state_line(state, "pending_question", label) do
    case value(state, "pending_question") do
      true -> "#{label}: waiting for user answer"
      _other -> nil
    end
  end

  def state_line(state, key, label) do
    case value(state, key) do
      value when value in [nil, "", []] -> nil
      value -> "#{label}: #{format_value(value)}"
    end
  end

  @spec rounds_line(map()) :: String.t() | nil
  def rounds_line(state) do
    answered = value(state, "answered_rounds")
    total = value(state, "total_rounds")

    if is_integer(answered) and is_integer(total),
      do: "rounds: #{answered} answered / #{total} total",
      else: nil
  end

  @spec completion_blockers_line(map()) :: String.t() | nil
  def completion_blockers_line(state) do
    case value(state, "completion_floor_failures") do
      failures when is_list(failures) and failures != [] ->
        "completion blocked: " <> Enum.map_join(failures, "; ", &format_value/1)

      _other ->
        nil
    end
  end

  @spec stability_line(map()) :: String.t() | nil
  def stability_line(state) do
    streak = value(state, "completion_candidate_streak")
    required = value(state, "streak_required")

    cond do
      is_nil(streak) -> nil
      is_nil(required) -> "stability: #{streak}"
      true -> "stability: #{streak}/#{required}"
    end
  end

  @spec format_value(term()) :: String.t()
  def format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  def format_value(value) when is_binary(value), do: value
  def format_value(value), do: to_string(value)

  @spec value(map(), String.t()) :: term()
  def value(map, key), do: InterviewMeta.value(map, key)
end
