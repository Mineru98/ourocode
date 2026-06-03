defmodule Ourocode.Terminal.EventLoopPromptInput do
  @moduledoc """
  Normalizes and dispatches natural-language prompt input events.
  """

  alias Ourocode.Plugin.UserLevel.Entry, as: UserLevelEntry
  alias Ourocode.Runtime.FocusState
  alias Ourocode.TaskRequest

  @spec normalize_line(String.t(), keyword() | map()) ::
          {:ok, {TaskRequest.t(), map()}} | {:error, String.t()}
  def normalize_line(line, options \\ [])

  def normalize_line(line, options) when is_binary(line) do
    options = Map.new(options)

    task_options =
      options
      |> Map.take([:id, :submitted_at_ms])
      |> Map.put(:source, Map.get(options, :task_source, :dashboard))

    with {:ok, task_request} <- TaskRequest.parse(line, task_options) do
      task_request = refine_user_level_route(task_request, options)
      {:ok, {task_request, input_event(task_request, Map.put_new(options, :raw_input, line))}}
    end
  end

  def normalize_line(_line, _options), do: {:error, "input line must be a string"}

  @spec dispatch_event(map(), map(), keyword() | map()) ::
          {:ok, TaskRequest.t()} | {:error, term()}
  def dispatch_event(input_event, startup_result, options \\ [])

  def dispatch_event(%{input_kind: :natural_language} = input_event, startup_result, options) do
    options = Map.new(options)

    with :ok <- validate_event(input_event),
         {:ok, task_request} <- task_request_from_event(input_event) do
      prompt_processor =
        Map.get(options, :on_prompt_input, &default_prompt_input_handler/3)

      prompt_processor.(task_request, input_event, startup_result)
      {:ok, task_request}
    end
  end

  def dispatch_event(%{input_kind: input_kind}, _startup_result, _options) do
    {:error, {:unsupported_input_kind, input_kind}}
  end

  def dispatch_event(_input_event, _startup_result, _options) do
    {:error, :invalid_prompt_input_event}
  end

  @spec input_event(TaskRequest.t(), keyword() | map()) :: map()
  def input_event(%TaskRequest{} = task_request, options) do
    options = Map.new(options)
    focus_state = Map.get(options, :focus_state, FocusState.new())
    focused_pane = Map.get(focus_state, :focused_pane, :task_prompt)
    steering_target = Map.get(focus_state, :steering_target, :parent)
    steering_target_pane_id = Map.get(focus_state, :steering_target_pane_id, focused_pane)
    steering_target_session_id = Map.get(focus_state, :steering_target_session_id)
    steering_target_kind = Map.get(focus_state, :steering_target_kind)
    steering_text = Map.get(options, :raw_input, task_request.task_input)

    steering_message =
      pane_directed_steering_message(
        steering_target_pane_id,
        steering_text,
        steering_target_session_id,
        steering_target_kind
      )

    %{
      type: :prompt_input_submitted,
      event_type: :prompt_input_submitted,
      source: :terminal_prompt,
      input_kind: :natural_language,
      focused_pane: focused_pane,
      steering_target: steering_target,
      steering_target_pane_id: steering_target_pane_id,
      steering_target_session_id: steering_target_session_id,
      steering_target_kind: steering_target_kind,
      task_request_id: task_request.id,
      task_input: task_request.task_input,
      raw_input: steering_text,
      steering_text: steering_text,
      steering_message: steering_message,
      submitted_at_ms: task_request.submitted_at_ms,
      occurred_at_ms: Map.get(options, :occurred_at_ms, task_request.submitted_at_ms),
      routing_decision: task_request.routing_decision,
      payload: %{
        task_request_id: task_request.id,
        task_source: task_request.source,
        task_input: task_request.task_input,
        raw_input: steering_text,
        steering_text: steering_text,
        focused_pane: focused_pane,
        steering_target: steering_target,
        steering_target_pane_id: steering_target_pane_id,
        steering_target_session_id: steering_target_session_id,
        steering_target_kind: steering_target_kind,
        steering_message: steering_message
      }
    }
  end

  @spec validate_event(map()) :: :ok | {:error, :invalid_prompt_input_event}
  def validate_event(%{
        type: :prompt_input_submitted,
        event_type: :prompt_input_submitted,
        source: :terminal_prompt,
        task_request_id: task_request_id,
        task_input: task_input,
        steering_text: steering_text,
        steering_message: %{
          type: :pane_directed_steering_message,
          target_pane_id: _target_pane_id,
          content: steering_text
        },
        submitted_at_ms: submitted_at_ms,
        payload: %{task_source: task_source}
      })
      when is_binary(task_request_id) and is_binary(task_input) and is_binary(steering_text) and
             is_integer(submitted_at_ms) and
             task_source in [:cli, :dashboard] do
    :ok
  end

  def validate_event(_input_event), do: {:error, :invalid_prompt_input_event}

  @spec task_request_from_event(map()) :: {:ok, TaskRequest.t()} | {:error, term()}
  def task_request_from_event(input_event) do
    with {:ok, task_request} <-
           TaskRequest.parse(input_event.task_input,
             id: input_event.task_request_id,
             source: input_event.payload.task_source,
             submitted_at_ms: input_event.submitted_at_ms
           ) do
      {:ok, restore_event_routing_decision(task_request, input_event)}
    end
  end

  defp restore_event_routing_decision(%TaskRequest{} = task_request, %{routing_decision: decision})
       when is_map(decision) do
    %{task_request | routing_decision: decision}
  end

  defp restore_event_routing_decision(%TaskRequest{} = task_request, _input_event),
    do: task_request

  defp refine_user_level_route(%TaskRequest{} = task_request, options) do
    capabilities = Map.get(options, :user_level_capabilities, [])
    UserLevelEntry.refine(task_request, capabilities)
  end

  defp refine_user_level_route(task_request, _options), do: task_request

  defp pane_directed_steering_message(
         target_pane_id,
         content,
         target_session_id,
         target_kind
       ) do
    %{
      type: :pane_directed_steering_message,
      target_pane_id: target_pane_id,
      content: content,
      target_session_id: target_session_id,
      target_kind: target_kind
    }
  end

  defp default_prompt_input_handler(_task_request, _input_event, _startup_result), do: :ok
end
