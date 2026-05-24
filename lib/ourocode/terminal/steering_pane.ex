defmodule Ourocode.Terminal.SteeringPane do
  @moduledoc """
  Applies prompt steering messages to the targeted child pane model.
  """

  alias Ourocode.Terminal.FocusNavigation

  @spec append_to_target_child_pane(map(), map()) :: map()
  def append_to_target_child_pane(%{panes: panes} = pane_model, input_event)
      when is_map(panes) and is_map(input_event) do
    steering_target = Map.get(input_event, :steering_target)
    target_pane_id = Map.get(input_event, :steering_target_pane_id)

    if steering_target in [:child, "child"] do
      case fetch_concrete_child_pane(panes, target_pane_id) do
        {:ok, pane_key, pane} ->
          updated_pane = append_steering_stream_entry(pane, input_event)
          %{pane_model | panes: Map.put(panes, pane_key, updated_pane)}

        :ignore ->
          pane_model
      end
    else
      pane_model
    end
  end

  def append_to_target_child_pane(pane_model, _input_event), do: pane_model

  defp fetch_concrete_child_pane(panes, target_pane_id) do
    target_key = FocusNavigation.pane_key(target_pane_id)

    Enum.find_value(panes, :ignore, fn {pane_key, pane} ->
      if concrete_child_pane?(pane, target_key) do
        {:ok, pane_key, pane}
      else
        false
      end
    end)
  end

  defp concrete_child_pane?(pane, target_key) when is_map(pane) do
    pane_id = pane |> Map.get(:id, Map.get(pane, "id")) |> FocusNavigation.pane_key()
    kind = Map.get(pane, :kind, Map.get(pane, "kind"))

    pane_id == target_key and kind in [:child_session, "child_session"]
  end

  defp concrete_child_pane?(_pane, _target_key), do: false

  defp append_steering_stream_entry(pane, input_event) when is_map(pane) do
    pane_state = Map.get(pane, :pane_state, Map.get(pane, "pane_state", %{}))
    pane_state = if is_map(pane_state), do: pane_state, else: %{}
    stream_entries = Map.get(pane_state, :stream_entries, [])
    stream_entries = if is_list(stream_entries), do: stream_entries, else: []

    updated_pane_state =
      pane_state
      |> Map.put(:stream_entries, stream_entries ++ [steering_stream_entry(input_event)])
      |> Map.put(:last_event_seq, Map.get(input_event, :event_seq))

    Map.put(pane, :pane_state, updated_pane_state)
  end

  defp steering_stream_entry(input_event) do
    steering_message = Map.get(input_event, :steering_message, %{})

    %{
      type: :pane_directed_steering_message,
      event_seq: Map.get(input_event, :event_seq),
      task_request_id: Map.get(input_event, :task_request_id),
      content: Map.get(steering_message, :content, Map.get(input_event, :steering_text)),
      target_pane_id:
        Map.get(steering_message, :target_pane_id, Map.get(input_event, :steering_target_pane_id)),
      target_session_id:
        Map.get(
          steering_message,
          :target_session_id,
          Map.get(input_event, :steering_target_session_id)
        ),
      target_kind:
        Map.get(steering_message, :target_kind, Map.get(input_event, :steering_target_kind)),
      payload: steering_message,
      occurred_at_ms: Map.get(input_event, :occurred_at_ms)
    }
  end
end
