defmodule Ourocode.Runtime.HookLifecycle do
  @moduledoc """
  Maintains the terminal-visible hook lifecycle projection.
  """

  alias Ourocode.MCP.LifecycleEvent

  @hook_event_types [:hook_started, :hook_progress, :hook_response, :hook_completed]

  @spec apply_events(map(), [map() | LifecycleEvent.t()]) :: map()
  def apply_events(hook_lifecycle, events) when is_map(hook_lifecycle) and is_list(events) do
    hook_events = Enum.filter(events, &hook_lifecycle_event?/1)

    hook_lifecycle
    |> Map.update(:events, hook_events, &(&1 ++ hook_events))
    |> Map.update(:event_count, length(hook_events), &(&1 + length(hook_events)))
    |> maybe_put_latest(:hook_started, :latest_started, hook_events)
    |> maybe_put_latest(:hook_progress, :latest_progress, hook_events)
    |> maybe_put_latest(:hook_response, :latest_response, hook_events)
    |> maybe_put_latest(:hook_completed, :latest_completed, hook_events)
  end

  @spec latest_event_seq([map() | LifecycleEvent.t()], map()) :: non_neg_integer()
  def latest_event_seq([], event_pipeline), do: Map.get(event_pipeline, :normalized_event_seq, 0)

  def latest_event_seq(events, event_pipeline) do
    events
    |> Enum.map(&event_value(&1, :event_seq))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> Map.get(event_pipeline, :normalized_event_seq, 0) + length(events)
      seqs -> Enum.max(seqs)
    end
  end

  defp maybe_put_latest(hook_lifecycle, event_type, key, hook_events) do
    hook_events
    |> Enum.filter(&(event_value(&1, :type) == event_type))
    |> List.last()
    |> case do
      nil -> hook_lifecycle
      event -> Map.put(hook_lifecycle, key, event)
    end
  end

  defp hook_lifecycle_event?(event), do: event_value(event, :type) in @hook_event_types

  defp event_value(%LifecycleEvent{} = event, key), do: Map.get(event, key)

  defp event_value(%{} = event, key),
    do: Map.get(event, key) || Map.get(event, Atom.to_string(key))
end
