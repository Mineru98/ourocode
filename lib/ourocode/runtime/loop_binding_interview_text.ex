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

  @spec summarize_initial_context(String.t(), pos_integer()) :: String.t()
  def summarize_initial_context(text, max_chars) when is_binary(text) and is_integer(max_chars) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(max(max_chars, 80))
  end

  def summarize_initial_context(_text, max_chars) when is_integer(max_chars),
    do: summarize_initial_context("", max_chars)

  @spec streak_after(non_neg_integer(), atom()) :: non_neg_integer()
  def streak_after(_streak, :user), do: 0
  def streak_after(streak, _source), do: streak + 1

  defp truncate(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      text
      |> String.slice(0, max_chars - 3)
      |> String.trim()
      |> Kernel.<>("...")
    end
  end
end
