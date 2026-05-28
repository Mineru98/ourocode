defmodule Ourocode.Terminal.RendererPausedInterview do
  @moduledoc """
  Projection helpers for the paused interview answer affordance.
  """

  alias Ourocode.Terminal.{Palette, TranscriptRows}

  @spec activity([term()], map()) :: [term()]
  def activity(activity, %{interview_paused: true}) do
    TranscriptRows.paused_interview_discussion(activity)
  end

  def activity(activity, _opts), do: activity

  @spec palette(map() | nil, String.t(), map()) :: map() | nil
  def palette(%{entries: entries} = palette, prompt_buffer, opts) do
    if Map.get(opts, :interview_paused, false) do
      if command_prompt?(prompt_buffer) do
        nil
      else
        controls = [answer_entry(), cancel_entry()]
        control_entries = Palette.filter(controls, prompt_buffer)
        entries = control_entries ++ Enum.reject(entries, &(&1.slash in ["/answer", "/cancel"]))
        index = Palette.clamp(Map.get(opts, :pidx, Map.get(palette, :index, 0)), length(entries))
        %{palette | entries: entries, index: index}
      end
    else
      palette
    end
  end

  def palette(palette, _prompt_buffer, _opts), do: palette

  @spec answer_query?(term()) :: boolean()
  def answer_query?(prompt_buffer) when is_binary(prompt_buffer) do
    prompt_buffer
    |> String.trim_leading()
    |> String.downcase()
    |> then(&(&1 == "/answer" or String.starts_with?(&1, "/answer ")))
  end

  def answer_query?(_prompt_buffer), do: false

  @spec cancel_query?(term()) :: boolean()
  def cancel_query?(prompt_buffer) when is_binary(prompt_buffer) do
    prompt_buffer
    |> String.trim_leading()
    |> String.downcase()
    |> then(&(&1 == "/cancel" or String.starts_with?(&1, "/cancel ")))
  end

  def cancel_query?(_prompt_buffer), do: false

  defp command_prompt?(prompt_buffer) when is_binary(prompt_buffer) do
    prompt_buffer
    |> String.trim_leading()
    |> String.starts_with?("/")
  end

  defp command_prompt?(_prompt_buffer), do: false

  @spec answer_entry() :: map()
  def answer_entry do
    %{
      slash: "/answer",
      name: "answer",
      summary: "Use while paused: /answer <answer> submits to the interview.",
      category: :interaction,
      source: :runtime,
      availability: :ready,
      aliases: [],
      args: [%{name: "answer", required?: true, description: "Interview answer text"}]
    }
  end

  @spec cancel_entry() :: map()
  def cancel_entry do
    %{
      slash: "/cancel",
      name: "cancel",
      summary: "Stop the paused interview and close the checkpoint.",
      category: :interaction,
      source: :runtime,
      availability: :ready,
      aliases: [],
      args: []
    }
  end
end
