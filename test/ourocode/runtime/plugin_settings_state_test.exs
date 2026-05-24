defmodule Ourocode.Runtime.PluginSettingsStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.PluginSettingsState

  test "session patch prefers explicit session_settings over legacy session key" do
    settings = %{
      "session" => %{"stream_mailbox_capacity" => 4},
      "session_settings" => %{"stream_mailbox_capacity" => 12}
    }

    assert PluginSettingsState.session_patch(settings) == %{"stream_mailbox_capacity" => 12}
  end

  test "pane patch falls back to legacy pane key" do
    assert PluginSettingsState.pane_patch(%{"pane" => %{"status_label" => "Insert"}}) == %{
             "status_label" => "Insert"
           }
  end

  test "builds plugin settings applied journal event" do
    event =
      PluginSettingsState.applied_event(
        %{
          "change" => "modified",
          "request_id" => "reload-1",
          "settings_source_path" => "/tmp/settings.json",
          "settings_source_relative_path" => ".ourocode/settings.json",
          "settings_source_signature" => "sig"
        },
        "plugin-a",
        "pane-a",
        self(),
        %{"session_settings" => %{}},
        %{"stream_mailbox_capacity" => 12},
        %{"status_label" => "Insert"},
        %{occurred_at_ms: 123}
      )

    assert event.type == :plugin_settings_applied
    assert event.plugin_id == "plugin-a"
    assert event.pane_id == "pane-a"
    assert event.session_pid == inspect(self())
    assert event.change == "modified"
    assert event.request_id == "reload-1"
    assert event.occurred_at_ms == 123
    refute event.ui_restart_required?
  end

  test "puts plugin settings on pane while preserving existing per-plugin settings" do
    pane = %{
      id: "pane-a",
      updated_at_ms: 1,
      pane_state: %{
        plugin_settings_by_plugin: %{"existing" => %{"enabled" => true}}
      }
    }

    event = %{request_id: "reload-2", change: :modified, occurred_at_ms: 456}

    updated =
      PluginSettingsState.put_on_pane(
        pane,
        "plugin-a",
        %{"session_settings" => %{}},
        %{"status_label" => "Insert"},
        event
      )

    assert updated.id == "pane-a"
    assert updated.updated_at_ms == 456
    assert updated.pane_state.plugin_settings == %{"session_settings" => %{}}
    assert updated.pane_state.plugin_settings_by_plugin["existing"] == %{"enabled" => true}

    assert updated.pane_state.plugin_settings_by_plugin["plugin-a"] == %{
             "session_settings" => %{}
           }

    assert updated.pane_state.plugin_pane_settings == %{"status_label" => "Insert"}

    assert updated.pane_state.last_plugin_settings_reload == %{
             plugin_id: "plugin-a",
             request_id: "reload-2",
             change: :modified,
             occurred_at_ms: 456
           }
  end
end
