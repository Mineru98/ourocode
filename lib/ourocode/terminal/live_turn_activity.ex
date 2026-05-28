defmodule Ourocode.Terminal.LiveTurnActivity do
  @moduledoc """
  Small, truthful live-turn feedback for the TUI.

  This is deliberately not chain-of-thought. It projects prompt-loop lifecycle
  events into short activity pulses so a submitted command feels alive while the
  workflow opens its first question, plan, or delegated work.
  """

  alias Ourocode.Terminal.PromptActivityIndicator

  @dispatch_steps [
    "routing command",
    "checking project context",
    "opening guided work",
    "preparing first visible update"
  ]

  @awaiting_steps [
    "waiting for the next update",
    "watching for first question",
    "listening for delegated work",
    "holding the prompt ready"
  ]

  @spec view(map() | nil, non_neg_integer()) :: [String.t()]
  def view(nil, _tick), do: []

  def view(%{prompt_state: prompt_state} = event, tick)
      when prompt_state in [:dispatching_input, :awaiting_prompt] do
    [
      "live: " <> headline(event),
      "  activity: " <> PromptActivityIndicator.frame(tick) <> " " <> activity_label(prompt_state),
      "  pulse: " <> step(prompt_state, tick)
    ]
  end

  def view(_event, _tick), do: []

  defp headline(%{task_input: task_input}) when is_binary(task_input) do
    task_input
    |> String.trim()
    |> mode_headline()
  end

  defp headline(%{accepted_prompt: task_input}) when is_binary(task_input) do
    task_input
    |> String.trim()
    |> mode_headline()
  end

  defp headline(%{prompt_state: :dispatching_input}), do: "dispatching prompt"
  defp headline(%{prompt_state: :awaiting_prompt}), do: "preparing your first step"
  defp headline(_event), do: "work is active"

  defp mode_headline(task_input) do
    downcased = String.downcase(task_input)

    cond do
      String.starts_with?(downcased, "ooo auto") ->
        "auto is preparing the plan"

      String.starts_with?(downcased, "ooo pm") ->
        "PM interview is opening"

      String.starts_with?(downcased, "ooo interview") ->
        "interview is opening"

      true ->
        "prompt accepted"
    end
  end

  defp step(:dispatching_input, tick),
    do: Enum.at(@dispatch_steps, rem(tick, length(@dispatch_steps)))

  defp step(:awaiting_prompt, tick),
    do: Enum.at(@awaiting_steps, rem(tick, length(@awaiting_steps)))

  defp activity_label(:dispatching_input), do: "accepted input is being routed"
  defp activity_label(:awaiting_prompt), do: "waiting for the first visible update"
end
