defmodule Ourocode.Runtime.LoopBindingInterviewText do
  @moduledoc """
  Small text helpers used by the LoopBindings interview relay.
  """

  @terminal_answers MapSet.new(["done", "cancel", "stop", "/cancel"])

  @spec initial_context_from_payload(map() | term()) :: String.t()
  def initial_context_from_payload(payload) when is_map(payload) do
    [
      get_in(payload, ["params", "arguments", "initial_context"]),
      get_in(payload, [:params, :arguments, :initial_context])
    ]
    |> Enum.find("", &(is_binary(&1) and String.trim(&1) != ""))
  end

  def initial_context_from_payload(_payload), do: ""

  @spec user_terminated?(String.t()) :: boolean()
  def user_terminated?(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.trim()
    |> then(&MapSet.member?(@terminal_answers, &1))
  end

  @spec ensure_user_prefix(String.t()) :: String.t()
  def ensure_user_prefix(text) when is_binary(text) do
    trimmed = String.trim(text)
    if String.starts_with?(trimmed, "[from-"), do: trimmed, else: "[from-user] " <> trimmed
  end

  @spec streak_after(non_neg_integer(), atom()) :: non_neg_integer()
  def streak_after(_streak, :user), do: 0
  def streak_after(streak, _source), do: streak + 1
end
