defmodule Ourocode.Terminal.CommandChildControlCommands do
  @moduledoc """
  Slash-command dispatch for controlling the focused child session.
  """

  alias Ourocode.Runtime.Dispatcher

  @actions [:interrupt_focused_child, :cancel_focused_child]

  @type action :: :interrupt_focused_child | :cancel_focused_child

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec dispatch(action(), map(), map()) :: {:ok, map()} | {:error, term()}
  def dispatch(:interrupt_focused_child, command_event, state) do
    Dispatcher.dispatch_interrupt_action(command_event, dispatch_options(state))
  end

  def dispatch(:cancel_focused_child, command_event, state) do
    case Dispatcher.dispatch_cancel_action(command_event, dispatch_options(state)) do
      {:error, reason}
      when reason in [:no_focused_child_session, :focused_child_session_pane_not_found] ->
        render_no_active_cancel(state)

      other ->
        other
    end
  end

  @spec dispatch_options(map()) :: map()
  def dispatch_options(state) when is_map(state) do
    state
    |> Map.get(:command_dispatch_options, %{})
    |> Map.new()
    |> Map.put(:focus_state, Map.get(state, :focus_state))
    |> Map.put(:pane_model, Map.get(state, :pane_model))
  end

  defp render_no_active_cancel(%{output: output}) when is_pid(output) do
    IO.puts(output, no_active_cancel_text())
    {:ok, no_active_cancel_result()}
  end

  defp render_no_active_cancel(_state), do: {:ok, no_active_cancel_result()}

  defp no_active_cancel_text do
    [
      "cancel: no active work",
      "  nothing is waiting for cancellation",
      "  next: start ooo pm <goal>, inspect /agents, or run /verify"
    ]
    |> Enum.join("\n")
  end

  defp no_active_cancel_result do
    %{
      cancel: %{
        status: :idle,
        message: "No active work to cancel.",
        next_actions: ["ooo pm <goal>", "/agents", "/verify"]
      }
    }
  end
end
