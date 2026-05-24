defmodule Ourocode.Runtime.ChildSessionActionDispatch do
  @moduledoc """
  Dispatches builtin interrupt/cancel actions to the currently focused child session.
  """

  alias Ourocode.Json
  alias Ourocode.Runtime.FocusState

  @spec dispatch_interrupt(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def dispatch_interrupt(command_event, options \\ [])

  def dispatch_interrupt(%{} = command_event, options) do
    dispatch_action(command_event, options, :interrupt)
  end

  def dispatch_interrupt(_command_event, _options), do: {:error, :invalid_interrupt_command_event}

  @spec dispatch_cancel(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def dispatch_cancel(command_event, options \\ [])

  def dispatch_cancel(%{} = command_event, options) do
    dispatch_action(command_event, options, :cancel)
  end

  def dispatch_cancel(_command_event, _options), do: {:error, :invalid_cancel_command_event}

  defp dispatch_action(command_event, options, action) do
    options = Map.new(options)
    context = options |> option(:context, %{}) |> Map.new()
    focus_state = option(options, :focus_state, Map.get(context, :focus_state, FocusState.new()))
    pane_model = option(options, :pane_model, Map.get(context, :pane_model, %{}))

    with :ok <- ensure_action(command_event, action),
         {:ok, focused_child} <- FocusState.focused_child_session(focus_state, pane_model),
         {:ok, serialized_request, decoded_request} <-
           serialize_request(command_event, focused_child, action),
         {:ok, delivery_result} <-
           deliver_request(
             focused_child.pane,
             serialized_request,
             decoded_request,
             options,
             context,
             action
           ) do
      {:ok,
       %{
         focused_child: Map.delete(focused_child, :pane),
         pane: focused_child.pane,
         serialized_request: serialized_request,
         decoded_request: decoded_request,
         delivery_result: delivery_result
       }}
    end
  end

  defp ensure_action(command_event, :interrupt) do
    command = map_value(command_event, :command)
    action = configured_action(command_event)

    cond do
      action in [:interrupt_focused_child, "interrupt_focused_child"] ->
        :ok

      command in ["/interrupt", "/stop-child"] ->
        :ok

      true ->
        {:error, {:unsupported_builtin_action, action || command}}
    end
  end

  defp ensure_action(command_event, :cancel) do
    command = map_value(command_event, :command)
    action = configured_action(command_event)

    cond do
      action in [:cancel_focused_child, "cancel_focused_child"] ->
        :ok

      command in ["/cancel", "/cancel-child"] ->
        :ok

      true ->
        {:error, {:unsupported_builtin_action, action || command}}
    end
  end

  defp configured_action(command_event) do
    run_spec = map_value(command_event, :run_spec) || %{}
    map_value(run_spec, :action) || map_value(command_event, :action)
  end

  defp serialize_request(command_event, focused_child, action) do
    pane = focused_child.pane
    command = map_value(command_event, :command)

    decoded_request = %{
      type: request_type(action),
      action: Atom.to_string(action),
      target_pane_id: string_value(focused_child.pane_id),
      target_session_id: string_value(focused_child.session_id),
      target_kind: string_value(focused_child.kind),
      child_id: string_value(focused_child.child_id),
      pane_id: string_value(map_value(pane, :id) || focused_child.pane_id),
      reason: action_reason(command_event, action),
      source: "terminal_command",
      source_command: string_value(command),
      source_args: List.wrap(map_value(command_event, :args)),
      source_event_seq: map_value(command_event, :event_seq),
      occurred_at_ms:
        map_value(command_event, :occurred_at_ms) || System.system_time(:millisecond)
    }

    {:ok, decoded_request |> Json.encode!() |> IO.iodata_to_binary(), decoded_request}
  end

  defp request_type(:interrupt), do: "child_session_interrupt_request"
  defp request_type(:cancel), do: "child_session_cancel_request"

  defp action_reason(command_event, action) do
    args = List.wrap(map_value(command_event, :args))

    case Enum.join(args, " ") do
      "" -> default_reason(action)
      reason -> reason
    end
  end

  defp default_reason(:interrupt), do: "user_requested_interrupt"
  defp default_reason(:cancel), do: "user_requested_cancel"

  defp deliver_request(pane, serialized_request, decoded_request, options, context, action) do
    dispatcher = action_dispatcher(options, action)
    delivery_context = Map.merge(context, %{decoded_request: decoded_request})

    cond do
      is_function(dispatcher, 3) ->
        normalize_delivery_result(dispatcher.(pane, serialized_request, delivery_context), action)

      is_function(dispatcher, 2) ->
        normalize_delivery_result(dispatcher.(pane, serialized_request), action)

      true ->
        {:error, dispatcher_not_configured(action)}
    end
  end

  defp action_dispatcher(options, :interrupt) do
    option(options, :child_session_interrupt_dispatcher, nil) ||
      option(options, :child_pane_interrupt_dispatcher, nil)
  end

  defp action_dispatcher(options, :cancel) do
    option(options, :child_session_cancel_dispatcher, nil) ||
      option(options, :child_pane_cancel_dispatcher, nil)
  end

  defp normalize_delivery_result(:ok, _action), do: {:ok, :ok}
  defp normalize_delivery_result({:ok, result}, _action), do: {:ok, result}
  defp normalize_delivery_result({:error, reason}, _action), do: {:error, reason}

  defp normalize_delivery_result(other, :interrupt),
    do: {:error, {:invalid_child_session_interrupt_dispatch_result, other}}

  defp normalize_delivery_result(other, :cancel),
    do: {:error, {:invalid_child_session_cancel_dispatch_result, other}}

  defp dispatcher_not_configured(:interrupt),
    do: :child_session_interrupt_dispatcher_not_configured

  defp dispatcher_not_configured(:cancel), do: :child_session_cancel_dispatcher_not_configured

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)

  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)
  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
end
