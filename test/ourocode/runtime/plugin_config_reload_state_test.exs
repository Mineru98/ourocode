defmodule Ourocode.Runtime.PluginConfigReloadStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Runtime.PluginConfigReloadState

  test "projects parsed plugin config into runtime plugin registry state" do
    plugin_config = plugin_config!()

    assert %{config_loaded?: true} = state = PluginConfigReloadState.config_state(plugin_config)
    assert state.enabled_plugins == ["enabled-plugin"]
    assert state.disabled_plugins == ["disabled-plugin"]
    assert Map.keys(state.plugins_by_id) |> Enum.sort() == ["disabled-plugin", "enabled-plugin"]
  end

  test "builds loaded reload state with metadata" do
    source_path = Path.expand("plugins.json")

    assert {:loaded, _plugin_config, plugins} =
             PluginConfigReloadState.reload_state(
               {:ok, source_path, plugin_config!()},
               %{previous: true},
               %{"request_id" => "reload-1", "change" => "modified"},
               %{occurred_at_ms: 123}
             )

    assert plugins.previous
    assert plugins.status == :ready
    assert plugins.config_loaded?
    refute plugins.config_missing?
    refute plugins.config_invalid?
    assert plugins.config_source_path == source_path
    assert plugins.last_reload.status == :loaded
    assert plugins.last_reload.request_id == "reload-1"
    assert plugins.last_reload.occurred_at_ms == 123
  end

  test "builds missing and invalid reload states" do
    assert {:missing, nil, missing} =
             PluginConfigReloadState.reload_state(
               {:missing, "missing.json", :not_found},
               %{},
               %{request_id: "reload-2"},
               %{occurred_at_ms: 456}
             )

    assert missing.status == :missing
    assert missing.config_missing?
    assert missing.config_error == :not_found
    assert missing.last_reload.status == :missing

    assert {:invalid, nil, invalid} =
             PluginConfigReloadState.reload_state(
               {:invalid, "invalid.json", :bad_json},
               %{},
               %{request_id: "reload-3"},
               %{occurred_at_ms: 789}
             )

    assert invalid.status == :invalid
    assert invalid.config_invalid?
    assert invalid.config_error == :bad_json
    assert invalid.last_reload.status == :invalid
  end

  test "builds plugin config reloaded journal event" do
    {_status, _config, plugins} =
      PluginConfigReloadState.reload_state(
        {:ok, Path.expand("plugins.json"), plugin_config!()},
        %{},
        %{request_id: "reload-4", change: :modified},
        %{occurred_at_ms: 321}
      )

    event =
      PluginConfigReloadState.reloaded_event(
        %{request_id: "reload-4", change: :modified},
        plugins,
        %{}
      )

    assert event.type == :plugin_config_reloaded
    assert event.status == :loaded
    assert event.request_id == "reload-4"
    assert event.change == :modified
    assert event.configured_plugin_count == 2
    assert event.enabled_plugins == ["enabled-plugin"]
    assert event.disabled_plugins == ["disabled-plugin"]
    assert event.occurred_at_ms == 321
    refute event.ui_restart_required?
  end

  defp plugin_config! do
    {:ok, plugin_config} =
      ConfigSchema.parse("""
      {
        "plugins": [
          {
            "identity": {"id": "enabled-plugin", "version": "1.0.0"},
            "path": "plugins/enabled",
            "entrypoint": {"type": "executable", "command": "bin/enabled"},
            "enabled": true,
            "source": "third_party",
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": ["bin/enabled"]
            }
          },
          {
            "identity": {"id": "disabled-plugin", "version": "1.0.0"},
            "path": "plugins/disabled",
            "entrypoint": {"type": "manifest", "path": "capabilities.json"},
            "enabled": false,
            "source": "third_party",
            "permissions": {
              "filesystem": [],
              "network": [],
              "process": []
            }
          }
        ]
      }
      """)

    plugin_config
  end
end
