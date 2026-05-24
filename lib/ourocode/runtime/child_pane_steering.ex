defmodule Ourocode.Runtime.ChildPaneSteering do
  @moduledoc """
  Resolves and delivers terminal steering messages to child panes.
  """

  alias Ourocode.Runtime.ChildPaneSteeringTarget

  @spec dispatch(map(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def dispatch(input_event, options \\ [])

  def dispatch(%{} = input_event, options) do
    options = Map.new(options)
    context = options |> option(:context, %{}) |> Map.new()

    with :ok <- ensure_child_steering_event(input_event),
         {:ok, steering_message} <- ChildPaneSteeringTarget.fetch_message(input_event),
         {:ok, pane} <-
           resolve_focused_child_pane(input_event, steering_message, options, context),
         {:ok, serialized_message, decoded_message} <-
           ChildPaneSteeringTarget.serialize(input_event, steering_message, pane),
         {:ok, delivery_result} <-
           deliver_steering_message(pane, serialized_message, decoded_message, options, context) do
      {:ok,
       %{
         pane: pane,
         serialized_message: serialized_message,
         decoded_message: decoded_message,
         delivery_result: delivery_result
       }}
    end
  end

  def dispatch(_input_event, _options), do: {:error, :invalid_steering_input_event}

  defp ensure_child_steering_event(input_event) do
    case map_value(input_event, :steering_target) do
      :child -> :ok
      "child" -> :ok
      other -> {:error, {:unsupported_steering_target, other}}
    end
  end

  defp resolve_focused_child_pane(input_event, steering_message, options, context) do
    pane_model = option(options, :pane_model, Map.get(context, :pane_model, %{}))
    ChildPaneSteeringTarget.resolve_pane(input_event, steering_message, pane_model, context)
  end

  defp deliver_steering_message(pane, serialized_message, decoded_message, options, context) do
    dispatcher = option(options, :child_pane_dispatcher, nil)
    delivery_context = Map.merge(context, %{decoded_message: decoded_message})

    cond do
      is_function(dispatcher, 3) ->
        normalize_delivery_result(dispatcher.(pane, serialized_message, delivery_context))

      is_function(dispatcher, 2) ->
        normalize_delivery_result(dispatcher.(pane, serialized_message))

      true ->
        {:error, :child_pane_dispatcher_not_configured}
    end
  end

  defp normalize_delivery_result(:ok), do: {:ok, :ok}
  defp normalize_delivery_result({:ok, result}), do: {:ok, result}
  defp normalize_delivery_result({:error, reason}), do: {:error, reason}

  defp normalize_delivery_result(other),
    do: {:error, {:invalid_child_pane_dispatch_result, other}}

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp option(options, key, default) when is_map(options), do: Map.get(options, key, default)
  defp option(options, key, default) when is_list(options), do: Keyword.get(options, key, default)
end
