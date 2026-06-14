defmodule Ourocode.Runtime.InterviewWonderPrompt do
  @moduledoc """
  Builds wonderTool checkpoint events for interview questions routed to users.
  """

  alias Ourocode.Runtime.InterviewResponse

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
        "type" => "multiple_choice_decision",
        "interaction_kind" => "socratic",
        "request_id" => "#{parent_call_id}-ask-#{round}",
        "parent_call_id" => parent_call_id,
        "questions" => [
          %{
            "id" => "interview",
            "header" => "Interview",
            "kind" => "socratic",
            "round" => round,
            "question" => InterviewResponse.clean_markdown(prompt),
            "options" => options(options, prompt)
          }
        ]
      }
    }
  end

  @spec options([map()], term()) :: [map()]
  def options(model_options, _prompt) when is_list(model_options) do
    model_options
    |> Enum.take(4)
    |> Enum.map(&option/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1["label"])
  end

  def options(_model_options, _prompt), do: []

  defp option(%{label: label, description: description}) do
    option(label, description)
  end

  defp option(%{"label" => label, "description" => description}) do
    option(label, description)
  end

  defp option(_option), do: nil

  defp option(label, description) do
    label = clean_field(label)
    description = clean_field(description)

    if usable?(label) and usable?(description) do
      %{"label" => label, "description" => description}
    end
  end

  defp clean_field(value) do
    value
    |> to_string()
    |> InterviewResponse.clean_markdown()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp usable?(text), do: is_binary(text) and String.length(String.trim(text)) >= 2
end
