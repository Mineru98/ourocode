defmodule Ourocode.Terminal.WorkflowLaneLifecycle do
  @moduledoc """
  Applies runtime-owned lifecycle events to workflow session panes.
  """

  @type event :: %{
          optional(:type) =>
            :stream_started
            | :stream_event
            | :paused
            | :resumed
            | :cancelled
            | :failed
            | :completed,
          optional(:line) => String.t(),
          optional(:phase) => String.t(),
          optional(:current) => String.t(),
          optional(:progress) => String.t() | [String.t()],
          optional(:controls) => [String.t()],
          optional(:parent_call_id) => String.t(),
          optional(:exit_code) => integer(),
          optional(:focused?) => boolean()
        }

  @spec apply_event(map(), String.t(), event()) :: map()
  def apply_event(pane_model, pane_id, event)
      when is_map(pane_model) and is_binary(pane_id) and is_map(event) do
    update_pane(pane_model, pane_id, fn pane ->
      apply_to_pane(pane, normalize_event(event))
    end)
  end

  @spec apply_events(map(), String.t(), [event()]) :: map()
  def apply_events(pane_model, pane_id, events)
      when is_map(pane_model) and is_binary(pane_id) and is_list(events) do
    Enum.reduce(events, pane_model, &apply_event(&2, pane_id, &1))
  end

  defp update_pane(pane_model, pane_id, fun) do
    panes = Map.get(pane_model, :panes, %{})

    case Map.fetch(panes, pane_id) do
      {:ok, pane} -> Map.put(pane_model, :panes, Map.put(panes, pane_id, fun.(pane)))
      :error -> pane_model
    end
  end

  defp apply_to_pane(pane, %{type: :stream_started} = event) do
    pane
    |> Map.put(:status, "running")
    |> Map.put(:last_line, Map.get(event, :line, "stream attached"))
    |> Map.put(:parent_call_id, Map.get(event, :parent_call_id, Map.get(pane, :parent_call_id)))
    |> put_event_fields(event)
    |> increment_event_count()
    |> put_focus(event)
  end

  defp apply_to_pane(pane, %{type: :stream_event} = event) do
    pane
    |> Map.put(:status, "running")
    |> Map.put(:last_line, Map.get(event, :line, Map.get(pane, :last_line, "stream event")))
    |> put_event_fields(event)
    |> increment_event_count()
    |> put_focus(event)
  end

  defp apply_to_pane(pane, %{type: :paused} = event) do
    pane
    |> Map.put(:status, "paused")
    |> Map.put(:last_line, Map.get(event, :line, "paused"))
    |> put_event_fields(event)
    |> increment_event_count()
    |> put_focus(event)
  end

  defp apply_to_pane(pane, %{type: :resumed} = event) do
    pane
    |> Map.put(:status, "running")
    |> Map.put(:last_line, Map.get(event, :line, "resumed"))
    |> put_event_fields(event)
    |> increment_event_count()
    |> put_focus(event)
  end

  defp apply_to_pane(pane, %{type: :cancelled} = event) do
    pane
    |> Map.put(:status, "cancelled")
    |> Map.put(:last_line, Map.get(event, :line, "cancel acknowledged"))
    |> Map.put(:parent_call_id, Map.get(event, :parent_call_id, Map.get(pane, :parent_call_id)))
    |> put_event_fields(event)
    |> increment_event_count()
  end

  defp apply_to_pane(pane, %{type: :failed} = event) do
    pane
    |> Map.put(:status, "failed")
    |> Map.put(:last_line, Map.get(event, :line, "error captured"))
    |> Map.put(:parent_call_id, Map.get(event, :parent_call_id, Map.get(pane, :parent_call_id)))
    |> Map.put(:exit_code, Map.get(event, :exit_code, 1))
    |> put_event_fields(event)
    |> increment_event_count()
  end

  defp apply_to_pane(pane, %{type: :completed} = event) do
    pane
    |> Map.put(:status, "completed")
    |> Map.put(:last_line, Map.get(event, :line, "completed"))
    |> put_event_fields(event)
    |> increment_event_count()
  end

  defp apply_to_pane(pane, _event), do: pane

  defp increment_event_count(pane) do
    Map.update(pane, :event_count, 1, fn
      count when is_integer(count) ->
        count + 1

      count when is_binary(count) ->
        case Integer.parse(count) do
          {value, ""} -> value + 1
          _other -> 1
        end

      _other ->
        1
    end)
  end

  defp put_event_fields(pane, event) do
    pane
    |> put_if_present(:phase, Map.get(event, :phase))
    |> put_if_present(:current, Map.get(event, :current))
    |> put_if_present(:progress, Map.get(event, :progress))
    |> put_if_present(:controls, Map.get(event, :controls))
  end

  defp put_if_present(pane, _key, nil), do: pane
  defp put_if_present(pane, _key, ""), do: pane
  defp put_if_present(pane, key, value), do: Map.put(pane, key, value)

  defp put_focus(pane, %{focused?: true}) do
    pane_state = Map.merge(Map.get(pane, :pane_state, %{}), %{focused?: true})
    Map.put(pane, :pane_state, pane_state)
  end

  defp put_focus(pane, _event), do: pane

  defp normalize_event(event) do
    event
    |> Enum.map(fn {key, value} -> {normalize_key(key), value} end)
    |> Map.new()
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
