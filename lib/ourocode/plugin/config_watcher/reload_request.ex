defmodule Ourocode.Plugin.ConfigWatcher.ReloadRequest do
  @moduledoc """
  Builds data-only plugin config watcher reload request events.
  """

  alias Ourocode.Plugin.ConfigWatcher.SnapshotDiff

  @spec build(map(), atom(), map()) :: map()
  def build(state, change, snapshot)
      when is_map(state) and is_atom(change) and is_map(snapshot) do
    occurred_at_ms = System.system_time(:millisecond)
    relative_path = Path.relative_to(snapshot.path, state.project_dir)

    base_event = %{
      type: :plugin_config_reload_requested,
      event_type: :plugin_config_reload_requested,
      source: :plugin_config_watcher,
      change: change,
      relevance: SnapshotDiff.relevance(change, snapshot),
      relevant?: true,
      config_source_exists?: snapshot.exists?,
      config_source_signature: signature(snapshot),
      occurred_at_ms: occurred_at_ms,
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false,
      watcher_id: state.watcher_id,
      request_id:
        request_id(state.watcher_id, snapshot.kind, relative_path, change, occurred_at_ms)
    }

    case snapshot.kind do
      :plugin_settings ->
        base_event
        |> Map.merge(%{
          type: :plugin_settings_reload_requested,
          event_type: :plugin_settings_reload_requested,
          relevance: :relevant_plugin_settings_change,
          reason: :plugin_scoped_settings_changed,
          plugin_id: snapshot.plugin_id,
          settings_source_path: snapshot.path,
          settings_source_relative_path: relative_path,
          settings_source_exists?: snapshot.exists?,
          settings_source_signature: signature(snapshot)
        })
        |> Map.delete(:config_source_exists?)
        |> Map.delete(:config_source_signature)

      _kind ->
        Map.merge(base_event, %{
          reason: :plugin_config_source_changed,
          config_source_path: snapshot.path,
          config_source_relative_path: relative_path
        })
    end
  end

  @spec request_id(String.t(), atom(), Path.t(), atom(), integer()) :: String.t()
  def request_id(watcher_id, kind, relative_path, change, occurred_at_ms) do
    [
      request_prefix(kind),
      watcher_id,
      change,
      relative_path,
      occurred_at_ms,
      System.unique_integer([:positive, :monotonic])
    ]
    |> Enum.map(&to_string/1)
    |> Enum.join(":")
  end

  defp signature(snapshot) do
    Map.take(snapshot, [:exists?, :size, :mtime, :checksum])
  end

  defp request_prefix(:plugin_settings), do: "plugin-settings-reload"
  defp request_prefix(_kind), do: "plugin-config-reload"
end
