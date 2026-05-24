defmodule Ourocode.Terminal.EventLoopLineFlow do
  @moduledoc """
  Routes a normalized terminal line into the event-loop flow that owns it.
  """

  alias Ourocode.Terminal.CommandHandler
  alias Ourocode.Terminal.CommandInput
  alias Ourocode.Terminal.EventLoopCommandDispatch
  alias Ourocode.Terminal.EventLoopExit
  alias Ourocode.Terminal.EventLoopPaletteFlow
  alias Ourocode.Terminal.EventLoopTaskSubmission

  @spec dispatch(String.t(), map()) ::
          {:ok, map()} | {:shutdown, String.t(), map()} | {:error, term()}
  def dispatch("", state) when is_map(state) do
    {:ok, %{state | iterations: state.iterations + 1}}
  end

  def dispatch(line, state) when is_binary(line) and is_map(state) do
    if EventLoopExit.shutdown_signal?(line, exit_signals: state.exit_signals) do
      IO.puts(state.output, "exiting ourocode")
      {:shutdown, line, %{state | iterations: state.iterations + 1}}
    else
      route_active_line(line, state)
    end
  end

  defp route_active_line(line, state) do
    cond do
      CommandInput.palette_selection?(line, state.active_command_palette) ->
        select_command_palette_entry(line, state)

      CommandInput.palette_trigger?(line) ->
        open_command_palette(line, state)

      CommandInput.slash_command?(line) ->
        submit_command(line, state)

      true ->
        EventLoopTaskSubmission.submit(line, state)
    end
  end

  defp submit_command(line, state) do
    line
    |> CommandInput.command_event()
    |> EventLoopCommandDispatch.submit(state)
  end

  defp open_command_palette(line, state) do
    {:ok, registry} = CommandHandler.registry(state)
    EventLoopPaletteFlow.open(line, state, registry)
  end

  defp select_command_palette_entry(line, state) do
    EventLoopPaletteFlow.select(line, state)
  end
end
