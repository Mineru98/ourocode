defmodule Ourocode.Plugin.ConfigWatcher.ReloadRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigWatcher.ReloadRequest

  test "build creates plugin config reload request events" do
    event =
      ReloadRequest.build(
        %{project_dir: "/repo", watcher_id: "watcher-1"},
        :modified,
        %{
          kind: :plugin_config,
          path: "/repo/.ourocode/config.json",
          exists?: true,
          size: 10,
          mtime: 1,
          checksum: "abc"
        }
      )

    assert event.type == :plugin_config_reload_requested
    assert event.event_type == :plugin_config_reload_requested
    assert event.source == :plugin_config_watcher
    assert event.change == :modified
    assert event.relevance == :relevant_config_change
    assert event.reason == :plugin_config_source_changed
    assert event.config_source_path == "/repo/.ourocode/config.json"
    assert event.config_source_relative_path == ".ourocode/config.json"
    assert event.config_source_exists? == true
    assert event.config_source_signature == %{exists?: true, size: 10, mtime: 1, checksum: "abc"}
    assert event.reload_boundary == :elixir_runtime
    assert event.ui_restart_required? == false
    assert event.watcher_id == "watcher-1"
    assert String.starts_with?(event.request_id, "plugin-config-reload:watcher-1:modified:")
  end

  test "build creates plugin settings reload request events" do
    event =
      ReloadRequest.build(
        %{project_dir: "/repo", watcher_id: "watcher-2"},
        :created,
        %{
          kind: :plugin_settings,
          plugin_id: "vim-mode",
          path: "/repo/plugins/vim-mode/settings.json",
          exists?: true,
          size: 11,
          mtime: 2,
          checksum: "def"
        }
      )

    assert event.type == :plugin_settings_reload_requested
    assert event.event_type == :plugin_settings_reload_requested
    assert event.relevance == :relevant_plugin_settings_change
    assert event.reason == :plugin_scoped_settings_changed
    assert event.plugin_id == "vim-mode"
    assert event.settings_source_path == "/repo/plugins/vim-mode/settings.json"
    assert event.settings_source_relative_path == "plugins/vim-mode/settings.json"

    assert event.settings_source_signature == %{
             exists?: true,
             size: 11,
             mtime: 2,
             checksum: "def"
           }

    refute Map.has_key?(event, :config_source_signature)
    assert String.starts_with?(event.request_id, "plugin-settings-reload:watcher-2:created:")
  end

  test "request_id includes source kind prefix and request identity parts" do
    assert ReloadRequest.request_id("watcher", :plugin_settings, "settings.json", :deleted, 123)
           |> String.starts_with?("plugin-settings-reload:watcher:deleted:settings.json:123:")

    assert ReloadRequest.request_id("watcher", :plugin_config, "config.json", :modified, 456)
           |> String.starts_with?("plugin-config-reload:watcher:modified:config.json:456:")
  end
end
