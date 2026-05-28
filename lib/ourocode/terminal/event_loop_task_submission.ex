defmodule Ourocode.Terminal.EventLoopTaskSubmission do
  @moduledoc """
  Natural-language task submission path for the terminal event loop.
  """

  alias Ourocode.Terminal.EventLoopJournal
  alias Ourocode.Terminal.EventLoopPromptFlow
  alias Ourocode.Terminal.EventLoopPromptInput
  alias Ourocode.Terminal.ParentWorkflowFeedback

  @spec submit(String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def submit(line, state) when is_binary(line) and is_map(state) do
    case EventLoopPromptInput.normalize_line(line,
           focus_state: state.focus_state,
           raw_input: line
         ) do
      {:ok, {_task_request, input_event}} ->
        accept_and_dispatch(input_event, state)

      {:error, reason} ->
        IO.puts(state.output, "ignored input: #{reason}")
        {:ok, %{state | iterations: state.iterations + 1}}
    end
  end

  defp accept_and_dispatch(input_event, state) do
    case EventLoopJournal.persist(state.journal_path, input_event) do
      {:ok, input_event} ->
        dispatch_accepted_input(input_event, state)

      {:error, reason} ->
        {:error, {:input_event_journal_append_failed, reason}}
    end
  end

  defp dispatch_accepted_input(input_event, state) do
    accepted_state =
      EventLoopPromptFlow.accept_input_event(state, input_event)

    accepted_state.on_input_event.(input_event, accepted_state.startup_result)

    dispatching_state =
      EventLoopPromptFlow.transition_state(
        accepted_state,
        :dispatching_input,
        input_event
      )

    render_parent_workflow_feedback(dispatching_state, input_event)

    case EventLoopPromptInput.dispatch_event(input_event, dispatching_state.startup_result,
           on_prompt_input: dispatching_state.on_prompt_input
         ) do
      {:ok, dispatched_task_request} ->
        awaiting_state =
          EventLoopPromptFlow.transition_state(
            dispatching_state,
            :awaiting_prompt,
            input_event
          )

        if ouroboros_workflow?(dispatched_task_request) do
          IO.puts(awaiting_state.output, workflow_start_line(dispatched_task_request))
          IO.puts(awaiting_state.output, workflow_next_line(dispatched_task_request))
        else
          IO.puts(
            awaiting_state.output,
            "task: queued #{dispatched_task_request.id} - #{dispatched_task_request.task_input}"
          )
        end

        awaiting_state = maybe_put_workflow_session(awaiting_state, dispatched_task_request)

        {:ok,
         %{
           awaiting_state
           | iterations: state.iterations + 1,
             submitted_tasks: [dispatched_task_request | state.submitted_tasks],
             input_events: [input_event | state.input_events]
         }}

      {:error, reason} ->
        {:error, {:prompt_input_dispatch_failed, reason}}
    end
  end

  defp render_parent_workflow_feedback(state, input_event) do
    state_event = hd(state.prompt_state_events)

    IO.puts(
      state.output,
      ParentWorkflowFeedback.render_text(input_event, state_event)
    )
  end

  defp ouroboros_workflow?(%{routing_decision: routing_decision}) when is_map(routing_decision) do
    route =
      Map.get(routing_decision, :execution_route) || Map.get(routing_decision, "execution_route")

    route in [:ouroboros_workflow, "ouroboros_workflow"]
  end

  defp ouroboros_workflow?(_task_request), do: false

  defp workflow_start_line(task_request) do
    "#{workflow_label(task_request)}: starting - #{task_request.task_input}"
  end

  defp workflow_next_line(task_request) do
    case workflow_mode(task_request) do
      :auto -> "auto: preparing an approval plan before file changes"
      :interview -> "interview: preparing the first clarification question"
      :pm -> "pm: preparing the first product question"
      :workflow -> "guided work: waiting for the first visible update"
    end
  end

  defp maybe_put_workflow_session(state, task_request) do
    if ouroboros_workflow?(task_request) do
      pane_id = "workflow:" <> task_request.id
      panes = Map.get(state.pane_model, :panes, %{})
      open = Map.get(state.pane_model, :open, [])
      mode = workflow_mode(task_request)

      pane = %{
        id: pane_id,
        kind: :workflow_session,
        session_id: task_request.id,
        title: workflow_label(task_request),
        status: workflow_status(mode),
        task: task_request.task_input,
        last_line: workflow_last_line(mode),
        progress: workflow_progress(mode),
        visible?: true
      }

      pane_model =
        state.pane_model
        |> Map.put(:panes, Map.put(panes, pane_id, pane))
        |> Map.put(:open, Enum.uniq(open ++ [pane_id]))

      %{state | pane_model: pane_model}
    else
      state
    end
  end

  defp workflow_mode(%{task_input: input}) when is_binary(input) do
    normalized = input |> String.trim() |> String.downcase()

    cond do
      normalized == "ooo auto" or String.starts_with?(normalized, "ooo auto ") ->
        :auto

      normalized == "ooo interview" or String.starts_with?(normalized, "ooo interview ") ->
        :interview

      normalized == "ooo pm" or String.starts_with?(normalized, "ooo pm ") ->
        :pm

      true ->
        :workflow
    end
  end

  defp workflow_mode(_task_request), do: :workflow

  defp workflow_label(task_request) do
    case workflow_mode(task_request) do
      :auto -> "Auto run"
      :interview -> "Socratic interview"
      :pm -> "PM interview"
      :workflow -> "Guided work"
    end
  end

  defp workflow_status(:auto), do: "preparing approval"
  defp workflow_status(:interview), do: "preparing question"
  defp workflow_status(:pm), do: "preparing question"
  defp workflow_status(:workflow), do: "preparing"

  defp workflow_last_line(:auto), do: "interview -> plan -> approval -> verify"
  defp workflow_last_line(:interview), do: "waiting for first clarification question"
  defp workflow_last_line(:pm), do: "waiting for first PM question"
  defp workflow_last_line(:workflow), do: "waiting for the first visible update"

  defp workflow_progress(:auto), do: "approval checkpoint before file changes"
  defp workflow_progress(:interview), do: "first question pending"
  defp workflow_progress(:pm), do: "answer choices pending"
  defp workflow_progress(:workflow), do: "first update pending"
end
