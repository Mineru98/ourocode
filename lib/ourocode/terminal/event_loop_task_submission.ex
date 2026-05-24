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

        IO.puts(
          awaiting_state.output,
          "queued task #{dispatched_task_request.id}: #{dispatched_task_request.task_input}"
        )

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
end
