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
    Dispatcher.dispatch_cancel_action(command_event, dispatch_options(state))
  end

  @spec dispatch_options(map()) :: map()
  def dispatch_options(state) when is_map(state) do
    state
    |> Map.get(:command_dispatch_options, %{})
    |> Map.new()
    |> Map.put(:focus_state, Map.get(state, :focus_state))
    |> Map.put(:pane_model, Map.get(state, :pane_model))
  end
end
