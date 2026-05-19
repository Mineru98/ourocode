defmodule Ourocode.Terminal.ParentWorkflowFeedback do
  @moduledoc """
  Terminal parent-pane feedback for accepted prompt workflow starts.

  The prompt loop owns input acceptance, while this module owns the terminal-safe
  projection that lets a user see the accepted prompt has entered the parent
  workflow pane before child events begin streaming.
  """

  @type rendered_feedback :: %{
          required(:kind) => :terminal_parent_workflow_feedback,
          required(:region) => :parent_pane,
          required(:status) => :workflow_starting,
          required(:task_request_id) => String.t(),
          required(:accepted_prompt) => String.t(),
          required(:workflow_route) => atom() | nil,
          required(:adapter_route) => atom() | nil,
          required(:prompt_state) => atom(),
          required(:line) => String.t()
        }

  @doc """
  Builds render-ready parent-pane feedback from the accepted prompt event and
  prompt-loop state transition event.
  """
  @spec render(map(), map()) :: rendered_feedback()
  def render(input_event, state_event) when is_map(input_event) and is_map(state_event) do
    feedback = %{
      kind: :terminal_parent_workflow_feedback,
      region: :parent_pane,
      status: :workflow_starting,
      task_request_id: Map.fetch!(input_event, :task_request_id),
      accepted_prompt: Map.fetch!(input_event, :task_input),
      workflow_route: route_value(input_event, :execution_route),
      adapter_route: route_value(input_event, :adapter_route),
      prompt_state: Map.fetch!(state_event, :prompt_state)
    }

    Map.put(feedback, :line, line_for(feedback))
  end

  @doc """
  Renders parent-pane workflow feedback as terminal-safe text.
  """
  @spec render_text(rendered_feedback() | map(), map() | nil) :: String.t()
  def render_text(feedback_or_input_event, state_event \\ nil)

  def render_text(%{kind: :terminal_parent_workflow_feedback} = feedback, _state_event) do
    [
      "+-- Parent Workflow region=parent_pane",
      "| " <> feedback.line,
      "+--"
    ]
    |> Enum.join("\n")
  end

  def render_text(input_event, state_event) when is_map(input_event) and is_map(state_event) do
    input_event
    |> render(state_event)
    |> render_text()
  end

  defp line_for(feedback) do
    [
      "[workflow-starting]",
      "state=#{feedback.prompt_state}",
      "task=#{feedback.task_request_id}",
      maybe_segment("route", feedback.workflow_route),
      maybe_segment("adapter", feedback.adapter_route),
      "accepted_prompt=" <> inspect(feedback.accepted_prompt)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp route_value(%{routing_decision: routing_decision}, key) when is_map(routing_decision) do
    Map.get(routing_decision, key) || Map.get(routing_decision, Atom.to_string(key))
  end

  defp route_value(_input_event, _key), do: nil

  defp maybe_segment(_key, nil), do: nil
  defp maybe_segment(key, value), do: key <> "=" <> to_string(value)
end
