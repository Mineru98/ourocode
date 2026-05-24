defmodule Ourocode.Plugin.HotReloadConfigStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.HotReloadConfigState

  test "build projects enabled and disabled plugin config state" do
    enabled = plugin!("enabled-plugin", true, settings: %{"mode" => "on"})
    disabled = plugin!("disabled-plugin", false)

    assert state = HotReloadConfigState.build([enabled, disabled])

    assert state.enabled_plugins == ["enabled-plugin"]
    assert state.disabled_plugins == ["disabled-plugin"]
    assert state.failed_plugins == []
    assert state.plugins_by_id["enabled-plugin"].settings == %{"mode" => "on"}
    assert state.plugins_by_id["disabled-plugin"].state == :disabled
  end

  test "replace_plugin_status updates existing plugins and appends new plugins" do
    state = HotReloadConfigState.build([plugin!("enabled-plugin", true)])

    updated =
      state.plugins_by_id["enabled-plugin"]
      |> Map.put(:enabled?, false)
      |> Map.put(:state, :disabled)

    state = HotReloadConfigState.replace_plugin_status(state, updated)

    assert state.enabled_plugins == []
    assert state.disabled_plugins == ["enabled-plugin"]
    assert state.configured_plugins == [updated]

    new_status = HotReloadConfigState.plugin_status(plugin!("new-plugin", true))
    state = HotReloadConfigState.replace_plugin_status(state, new_status)

    assert Enum.map(state.configured_plugins, & &1.id) == ["enabled-plugin", "new-plugin"]
    assert state.enabled_plugins == ["new-plugin"]
  end

  test "settings_transition records reload source state" do
    target = HotReloadConfigState.plugin_status(plugin!("settings-plugin", true))

    assert HotReloadConfigState.settings_transition(nil, target) == %{
             plugin_id: "settings-plugin",
             from: :unconfigured,
             to: :enabled,
             action: :settings_reloaded,
             loadable?: true,
             reason: :plugin_settings_changed
           }

    previous = %{target | state: :disabled, enabled?: false}

    assert HotReloadConfigState.settings_transition(previous, target).from == :disabled
  end

  test "put_failed_plugin_status updates failed plugin index" do
    state = HotReloadConfigState.build([plugin!("failed-plugin", true)])

    failed =
      state.plugins_by_id["failed-plugin"]
      |> Map.put(:state, :load_failed)
      |> Map.put(:load_error, %{reason: :boom})

    state = HotReloadConfigState.put_failed_plugin_status(state, failed)

    assert state.failed_plugins == ["failed-plugin"]
    assert state.plugins_by_id["failed-plugin"].load_error == %{reason: :boom}
    assert HotReloadConfigState.failed_plugin_ids(state.plugins_by_id) == ["failed-plugin"]
  end

  defp plugin!(id, enabled, opts \\ []) do
    path = Keyword.get(opts, :path, "plugins/#{id}")
    settings = Keyword.get(opts, :settings, %{})

    %ConfigSchema.PluginEntry{
      id: id,
      identity: %{"id" => id, "version" => "1.0.0"},
      package_identity: %ConfigSchema.PackageIdentity{id: id, version: "1.0.0"},
      path: path,
      entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
      enabled: enabled,
      source: "third_party",
      provenance: %{},
      trust_policy: %{"tier" => "community_code", "requires_explicit_approval" => true},
      trust_policy_state: "absent_defaulted",
      trust_evaluation: %{"trust_classification" => "community_code"},
      permissions: %{"filesystem" => [], "network" => [], "process" => []},
      transports: [],
      settings: settings
    }
  end
end
