defmodule Ourocode.Runtime.ChildPaneSteeringTarget do
  @moduledoc """
  Resolves focused child panes and serializes pane-directed steering messages.
  """

  alias Ourocode.Json

  @spec fetch_message(map()) :: {:ok, map()} | {:error, :missing_pane_directed_steering_message}
  def fetch_message(input_event) do
    case map_value(input_event, :steering_message) do
      %{type: :pane_directed_steering_message} = message -> {:ok, message}
      %{"type" => "pane_directed_steering_message"} = message -> {:ok, message}
      %{"type" => :pane_directed_steering_message} = message -> {:ok, message}
      %{type: "pane_directed_steering_message"} = message -> {:ok, message}
      _message -> {:error, :missing_pane_directed_steering_message}
    end
  end

  @spec resolve_pane(map(), map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_pane(input_event, steering_message, pane_model, context) do
    target_pane_id = target_pane_id(input_event, steering_message, context)

    with {:ok, pane_id} <- require_target_pane_id(target_pane_id),
         {:ok, pane} <- pane_from_model(pane_model, pane_id),
         :ok <- ensure_child_pane(pane, pane_id) do
      {:ok, pane}
    end
  end

  @spec serialize(map(), map(), map()) :: {:ok, String.t(), map()}
  def serialize(input_event, steering_message, pane) do
    resolved_pane_id = map_value(pane, :id)
    resolved_session_id = map_value(pane, :child_id) || map_value(pane, :session_id)
    resolved_kind = map_value(pane, :kind)

    decoded_message = %{
      type: "pane_directed_steering_message",
      content:
        string_value(
          map_value(steering_message, :content) || map_value(input_event, :steering_text)
        ),
      target_pane_id:
        string_value(
          resolved_pane_id ||
            map_value(steering_message, :target_pane_id) ||
            map_value(input_event, :steering_target_pane_id)
        ),
      target_session_id:
        string_value(
          resolved_session_id ||
            map_value(steering_message, :target_session_id) ||
            map_value(input_event, :steering_target_session_id)
        ),
      target_kind:
        string_value(
          resolved_kind ||
            map_value(steering_message, :target_kind) ||
            map_value(input_event, :steering_target_kind)
        ),
      task_request_id: string_value(map_value(input_event, :task_request_id)),
      task_input: string_value(map_value(input_event, :task_input)),
      focused_pane: string_value(map_value(input_event, :focused_pane)),
      steering_target: string_value(map_value(input_event, :steering_target)),
      source_event_seq: map_value(input_event, :event_seq),
      pane_id: string_value(resolved_pane_id),
      child_id: string_value(resolved_session_id)
    }

    {:ok, decoded_message |> Json.encode!() |> IO.iodata_to_binary(), decoded_message}
  end

  defp target_pane_id(input_event, steering_message, context) do
    focus_state =
      map_value(context, :focus_state) ||
        map_value(input_event, :focus_state) ||
        %{}

    map_value(focus_state, :steering_target_pane_id) ||
      map_value(focus_state, :focused_pane) ||
      map_value(input_event, :steering_target_pane_id) ||
      map_value(input_event, :focused_pane) ||
      map_value(steering_message, :target_pane_id)
  end

  defp require_target_pane_id(pane_id) when is_binary(pane_id) and pane_id != "",
    do: {:ok, pane_id}

  defp require_target_pane_id(pane_id) when is_atom(pane_id) and not is_nil(pane_id),
    do: {:ok, pane_id}

  defp require_target_pane_id(_pane_id), do: {:error, :missing_steering_target_pane_id}

  defp pane_from_model(%{panes: panes}, pane_id) when is_map(panes) do
    case Map.get(panes, pane_id) || Map.get(panes, pane_key(pane_id)) ||
           pane_by_id(panes, pane_id) do
      nil -> {:error, {:focused_child_pane_not_found, pane_id}}
      pane when is_map(pane) -> {:ok, Map.put_new(pane, :id, pane_id)}
      pane -> {:error, {:invalid_focused_child_pane, pane}}
    end
  end

  defp pane_from_model(%{"panes" => panes}, pane_id) when is_map(panes) do
    pane_from_model(%{panes: panes}, pane_id)
  end

  defp pane_from_model(_pane_model, pane_id),
    do: {:error, {:focused_child_pane_not_found, pane_id}}

  defp pane_by_id(panes, pane_id) do
    Enum.find_value(panes, fn
      {_key, %{id: ^pane_id} = pane} -> pane
      {_key, %{"id" => ^pane_id} = pane} -> pane
      {_key, _pane} -> nil
    end)
  end

  defp ensure_child_pane(pane, pane_id) do
    kind = map_value(pane, :kind)

    cond do
      kind in [:child_session, "child_session", :child_sessions, "child_sessions"] ->
        :ok

      child_pane_id?(pane_id) ->
        :ok

      true ->
        {:error, {:focused_pane_is_not_child, pane_id, kind}}
    end
  end

  defp child_pane_id?(pane_id) when is_binary(pane_id) do
    String.starts_with?(pane_id, ["child-", "child:", "child-session:", "child-pane:"])
  end

  defp child_pane_id?(_pane_id), do: false

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp pane_key(pane_id) when is_atom(pane_id), do: Atom.to_string(pane_id)
  defp pane_key(pane_id) when is_binary(pane_id), do: pane_id
  defp pane_key(pane_id), do: inspect(pane_id)

  defp string_value(nil), do: nil
  defp string_value(value) when is_binary(value), do: value
  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value), do: to_string(value)
end
