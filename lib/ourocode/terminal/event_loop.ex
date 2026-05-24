defmodule Ourocode.Terminal.EventLoop do
  @moduledoc """
  Persistent terminal input loop for the interactive baseline.

  The loop deliberately stays small: it owns terminal input continuity, accepts
  natural-language task submissions, and exits only on explicit user exit
  commands or stdin EOF for non-interactive smoke runs.
  """

  alias Ourocode.TaskRequest
  alias Ourocode.Terminal.EventLoopFocus
  alias Ourocode.Terminal.EventLoopExit
  alias Ourocode.Terminal.EventLoopInput
  alias Ourocode.Terminal.EventLoopLineFlow
  alias Ourocode.Terminal.EventLoopPromptInput
  alias Ourocode.Terminal.EventLoopResources
  alias Ourocode.Terminal.EventLoopState
  alias Ourocode.Terminal.RuntimeEventProcessor

  @default_prompt "ourocode> "

  @type result :: %{
          required(:status) => :exit_signal_received | :input_eof,
          required(:iterations) => non_neg_integer(),
          required(:submitted_tasks) => [TaskRequest.t()],
          required(:input_events) => [map()],
          required(:accepted_input_buffer) => [map()],
          required(:runtime_events) => [map()],
          required(:plugin_status_updates) => [map()],
          required(:command_events) => [map()],
          required(:command_palette_events) => [map()],
          required(:command_errors) => [map()],
          required(:focus_events) => [map()],
          required(:focus_state) => map(),
          required(:pane_model) => map(),
          required(:recoverable_errors) => [map()],
          required(:prompt_state) => :awaiting_prompt | :dispatching_input,
          required(:prompt_state_events) => [map()],
          required(:exit_signal) => String.t() | nil,
          required(:resources_released?) => boolean()
        }

  @doc """
  Runs the terminal prompt loop until an explicit exit command or EOF.
  """
  @spec run(map(), keyword() | map()) :: {:ok, result()} | {:error, term()}
  def run(startup_result, options \\ []) when is_map(startup_result) do
    startup_result
    |> EventLoopState.build(options, @default_prompt)
    |> loop()
  end

  @doc """
  Converts one natural-language terminal line into the normalized input event
  emitted by the prompt loop.
  """
  @spec normalize_input_line(String.t(), keyword() | map()) ::
          {:ok, {TaskRequest.t(), map()}} | {:error, String.t()}
  def normalize_input_line(line, options \\ []) do
    EventLoopPromptInput.normalize_line(line, options)
  end

  @doc """
  Dispatches a normalized natural-language prompt event into the prompt
  processing path.

  This keeps the app input boundary event-first: terminal input is normalized
  and journaled before any prompt-processing callback receives it.
  """
  @spec dispatch_prompt_input_event(map(), map(), keyword() | map()) ::
          {:ok, TaskRequest.t()} | {:error, term()}
  def dispatch_prompt_input_event(input_event, startup_result, options \\ [])

  def dispatch_prompt_input_event(
        %{input_kind: :natural_language} = input_event,
        startup_result,
        options
      ) do
    EventLoopPromptInput.dispatch_event(input_event, startup_result, options)
  end

  def dispatch_prompt_input_event(input_event, startup_result, options) do
    EventLoopPromptInput.dispatch_event(input_event, startup_result, options)
  end

  @doc """
  Returns true only when a terminal line exactly matches an explicit exit
  command or an exit signal configured for this prompt loop.
  """
  @spec shutdown_signal?(term(), keyword() | map()) :: boolean()
  def shutdown_signal?(line, options \\ [])

  def shutdown_signal?(line, options), do: EventLoopExit.shutdown_signal?(line, options)

  defp loop(state) do
    case RuntimeEventProcessor.drain(state) do
      {:ok, state} ->
        case EventLoopInput.read(state) do
          :eof ->
            finish(:input_eof, nil, state)

          {:line, line} ->
            handle_line(line, state)

          {:keyboard, key_input} ->
            handle_keyboard_input(key_input, state)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_line(line, state) do
    case EventLoopLineFlow.dispatch(line, state) do
      {:ok, state} -> loop(state)
      {:shutdown, exit_signal, state} -> shutdown(:exit_signal_received, exit_signal, state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_keyboard_input(key_input, state) do
    case EventLoopFocus.handle_keyboard(key_input, state) do
      {:ok, state} -> loop(state)
      {:error, reason} -> {:error, reason}
    end
  end

  defp shutdown(status, exit_signal, state) do
    with {:ok, state} <- RuntimeEventProcessor.drain(state),
         :ok <- EventLoopResources.release_active(state) do
      finish(status, exit_signal, state, true)
    end
  end

  defp finish(status, exit_signal, state, resources_released? \\ false) do
    {:ok, EventLoopExit.result(status, exit_signal, state, resources_released?)}
  end
end
