defmodule Ourocode.Terminal.EventLoopExit do
  @moduledoc """
  Exit-signal normalization and terminal loop result construction.
  """

  @default_exit_commands MapSet.new(["/exit", "/quit", "exit", "quit", ":q"])

  @spec exit_signals(keyword() | map()) :: MapSet.t(String.t())
  def exit_signals(options) do
    options = Map.new(options)

    configured =
      options
      |> Map.get(:exit_signals, [])
      |> normalize_configured_exit_signals()

    MapSet.union(@default_exit_commands, configured)
  end

  @spec shutdown_signal?(term(), keyword() | map()) :: boolean()
  def shutdown_signal?(line, options \\ [])

  def shutdown_signal?(line, options) when is_binary(line) do
    line
    |> normalize_shutdown_signal()
    |> then(&MapSet.member?(exit_signals(options), &1))
  end

  def shutdown_signal?(_line, _options), do: false

  @spec result(atom(), String.t() | nil, map(), boolean()) :: map()
  def result(status, exit_signal, state, resources_released? \\ false) do
    %{
      status: status,
      iterations: state.iterations,
      submitted_tasks: Enum.reverse(state.submitted_tasks),
      input_events: Enum.reverse(state.input_events),
      accepted_input_buffer: Enum.reverse(state.accepted_input_buffer),
      runtime_events: Enum.reverse(state.runtime_events),
      plugin_status_updates: Enum.reverse(state.plugin_status_updates),
      command_events: Enum.reverse(state.command_events),
      command_palette_events: Enum.reverse(state.command_palette_events),
      command_errors: Enum.reverse(state.command_errors),
      focus_events: Enum.reverse(state.focus_events),
      focus_state: state.focus_state,
      pane_model: state.pane_model,
      recoverable_errors: Enum.reverse(state.recoverable_errors),
      prompt_state: state.prompt_state,
      prompt_state_events: Enum.reverse(state.prompt_state_events),
      exit_signal: exit_signal,
      resources_released?: resources_released?
    }
  end

  defp normalize_configured_exit_signals(signals) when is_list(signals) do
    signals
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_shutdown_signal/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp normalize_configured_exit_signals(%MapSet{} = signals) do
    signals
    |> MapSet.to_list()
    |> normalize_configured_exit_signals()
  end

  defp normalize_configured_exit_signals(_signals), do: MapSet.new()

  defp normalize_shutdown_signal(line) do
    line
    |> String.trim()
    |> String.downcase()
  end
end
