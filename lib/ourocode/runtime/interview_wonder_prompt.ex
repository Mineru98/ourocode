defmodule Ourocode.Runtime.InterviewWonderPrompt do
  @moduledoc """
  Builds wonderTool checkpoint events for interview questions routed to users.
  """

  alias Ourocode.Runtime.{InterviewOptionSynthesizer, InterviewResponse}

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
            "round" => round,
            "question" => InterviewResponse.clean_markdown(prompt),
            "options" => options(options, prompt)
          }
        ]
      }
    }
  end

  @spec options([map()], term()) :: [map()]
  def options(model_options, prompt),
    do: InterviewOptionSynthesizer.options(model_options, prompt)
end
