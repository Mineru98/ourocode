defmodule Ourocode.Runtime.InterviewOptionSynthesizer do
  @moduledoc """
  Builds durable suggested-answer options for interview checkpoints.

  Model-supplied options are preferred. When the router cannot provide them,
  this module derives concrete choices from the prompt text and finally falls
  back to decision-oriented defaults so the UI never has only free text.
  """

  alias Ourocode.Runtime.InterviewResponse

  @generic_ask_options [
    %{
      "label" => "Answer in my own words",
      "description" => "Type a free-text answer instead of picking"
    },
    %{"label" => "Not sure - skip for now", "description" => "I can't decide this yet"}
  ]

  @decision_fallback_options [
    %{
      "label" => "Narrow the scope",
      "description" => "Focus the interview on the smallest useful decision"
    },
    %{
      "label" => "Broaden the scope",
      "description" => "Keep multiple related concerns in the interview"
    },
    %{
      "label" => "Prioritize release readiness",
      "description" => "Optimize the answer for shipping a stable next version"
    }
  ]

  @spec options([map()], term()) :: [map()]
  def options(model_options, prompt) do
    mapped =
      model_options
      |> model_options()
      |> Enum.take(4)
      |> Enum.map(&option/1)
      |> Enum.reject(&is_nil/1)

    choices =
      case mapped do
        [] -> synthesized_options(prompt)
        options -> options
      end

    choices
    |> append_generic_options()
    |> Enum.uniq_by(& &1["label"])
    |> Enum.take(max(2, length(choices)))
  end

  defp model_options(options) when is_list(options), do: options
  defp model_options(_options), do: []

  defp option(%{label: label, description: description}) do
    %{"label" => to_string(label), "description" => to_string(description)}
  end

  defp option(%{"label" => label, "description" => description}) do
    %{"label" => to_string(label), "description" => to_string(description)}
  end

  defp option(_option), do: nil

  defp synthesized_options(prompt) do
    prompt
    |> prompt_option_hints()
    |> case do
      [] -> @decision_fallback_options
      options -> options
    end
  end

  defp append_generic_options(options), do: options ++ @generic_ask_options

  defp prompt_option_hints(prompt) when is_binary(prompt) do
    prompt
    |> option_candidate_text()
    |> split_option_candidates()
    |> normalize_candidates()
  end

  defp prompt_option_hints(_prompt), do: []

  defp option_candidate_text(prompt) do
    text = InterviewResponse.clean_markdown(prompt)

    case Regex.split(~r/[?？:：]/u, text, parts: 2) do
      [before, rest] ->
        rest = String.trim(rest)
        if rest == "", do: before, else: rest

      [only] ->
        only
    end
  end

  defp trim_candidate(text) do
    Regex.replace(~r/\A[\s.!?;:]+|[\s.!?;:]+\z/u, text, "")
  end

  defp split_option_candidates(text) do
    text
    |> String.replace(~r/\b(?:or|versus|vs\.?)\b/iu, ",")
    |> String.replace(~r/\b(?:and)\b/iu, ",")
    |> String.replace(~r/\s*(?:아니면|또는|혹은)\s*/u, ",")
    |> String.split(~r/\s*[,，、]\s*/u)
  end

  defp normalize_candidates(candidates) when length(candidates) < 2, do: []

  defp normalize_candidates(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, index} ->
      candidate
      |> String.trim()
      |> maybe_strip_question_prefix(index)
      |> trim_candidate()
    end)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
    |> Enum.take(4)
    |> Enum.map(fn label ->
      %{"label" => label, "description" => "Focus the interview on #{label}"}
    end)
  end

  defp maybe_strip_question_prefix(candidate, 0) do
    Regex.replace(
      ~r/\A(?:should we|which|what|where|when|how|do we|does this|is this)\b.*?\b(?:on|for|between|around|about)\s+/iu,
      candidate,
      ""
    )
  end

  defp maybe_strip_question_prefix(candidate, _index), do: candidate
end
