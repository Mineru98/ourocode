defmodule Ourocode.Runtime.InterviewWonderPrompt do
  @moduledoc """
  Builds wonderTool checkpoint events for interview questions routed to users.
  """

  alias Ourocode.Runtime.InterviewResponse

  @generic_ask_options [
    %{
      "label" => "Answer in my own words",
      "description" => "Type a free-text answer instead of picking"
    },
    %{"label" => "Not sure — skip for now", "description" => "I can't decide this yet"}
  ]

  @spec event(String.t(), non_neg_integer(), String.t(), [map()]) :: map()
  def event(parent_call_id, round, prompt, options) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :wonder_tool,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        "tool" => "wonderTool",
        "request_id" => "#{parent_call_id}-ask-#{round}",
        "parent_call_id" => parent_call_id,
        "questions" => [
          %{
            "id" => "interview",
            "header" => "Interview",
            "question" => InterviewResponse.clean_markdown(prompt),
            "options" => options(options, prompt)
          }
        ]
      }
    }
  end

  @spec options([map()], term()) :: [map()]
  def options(model_options, prompt) do
    model_options =
      case model_options do
        [] -> prompt_option_hints(prompt)
        other when is_list(other) -> other
        _other -> []
      end

    mapped =
      model_options
      |> Enum.take(4)
      |> Enum.map(&option/1)
      |> Enum.reject(&is_nil/1)

    (@generic_ask_options ++ mapped)
    |> prefer_model_order(mapped)
    |> Enum.uniq_by(& &1["label"])
    |> Enum.take(max(2, length(mapped)))
  end

  defp option(%{label: label, description: description}) do
    %{"label" => to_string(label), "description" => to_string(description)}
  end

  defp option(%{"label" => label, "description" => description}) do
    %{"label" => to_string(label), "description" => to_string(description)}
  end

  defp option(_option), do: nil

  defp prefer_model_order(options, []), do: options
  defp prefer_model_order(_options, mapped), do: mapped ++ @generic_ask_options

  defp prompt_option_hints(prompt) when is_binary(prompt) do
    prompt
    |> option_candidate_text()
    |> split_option_candidates()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim(&1, " .!?;:"))
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.uniq()
    |> Enum.take(4)
    |> Enum.map(fn label ->
      %{label: label, description: "Focus the interview on #{label}"}
    end)
  end

  defp prompt_option_hints(_prompt), do: []

  defp option_candidate_text(prompt) do
    text = InterviewResponse.clean_markdown(prompt)

    case Regex.split(~r/[?？:：]/u, text, parts: 2) do
      [_before, rest] -> rest
      [only] -> only
    end
  end

  defp split_option_candidates(text) do
    text
    |> String.replace(~r/\b(?:or|versus|vs\.?)\b/iu, ",")
    |> String.replace(~r/\b(?:and)\b/iu, ",")
    |> String.replace(~r/\s*(?:아니면|또는|혹은)\s*/u, ",")
    |> String.split(~r/\s*[,，、]\s*/u)
  end
end
