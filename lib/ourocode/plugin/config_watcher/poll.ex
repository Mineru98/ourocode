defmodule Ourocode.Plugin.ConfigWatcher.Poll do
  @moduledoc """
  Executes one plugin config watcher poll cycle.
  """

  alias Ourocode.Journal
  alias Ourocode.Plugin.ConfigWatcher.ReloadRequest
  alias Ourocode.Plugin.ConfigWatcher.SnapshotDiff
  alias Ourocode.Plugin.ConfigWatcher.Sources

  @spec run(map()) :: {[map()], map()}
  def run(state) when is_map(state) do
    next_snapshots = Sources.snapshots(state.watch_sources)
    changes = SnapshotDiff.diff(state.snapshots, next_snapshots)

    emitted_events =
      changes
      |> Enum.map(fn {change, snapshot} -> ReloadRequest.build(state, change, snapshot) end)
      |> Enum.map(&emit_event(state, &1))

    state =
      state
      |> Map.put(:snapshots, next_snapshots)
      |> Map.put(:last_reload_requests, emitted_events)
      |> Map.update!(:emitted_count, &(&1 + length(emitted_events)))

    {emitted_events, state}
  end

  @spec emit_event(map(), map()) :: map()
  def emit_event(state, event) when is_map(state) and is_map(event) do
    event = journal_event(Map.get(state, :journal_path), event)

    state
    |> Map.get(:subscribers, [])
    |> Enum.each(fn
      pid when is_pid(pid) -> send(pid, {event.type, event})
      _subscriber -> :ok
    end)

    event
  end

  defp journal_event(path, event) when is_binary(path) do
    case Journal.append_returning_event(path, event) do
      {:ok, journaled_event} -> journaled_event
      {:error, reason} -> Map.put(event, :journal_error, reason)
    end
  end

  defp journal_event(_path, event), do: event
end
