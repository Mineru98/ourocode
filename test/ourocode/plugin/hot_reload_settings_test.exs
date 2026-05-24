defmodule Ourocode.Plugin.HotReloadSettingsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.HotReloadConfigState
  alias Ourocode.Plugin.HotReloadSettings
  alias Ourocode.Plugin.ConfigSchema

  test "apply updates settings without changing the active registry" do
    plugin_entry = plugin_entry(%{"mode" => "fast"})
    state = %{generation: 3, registry: %{actions: %{{:session, :open} => :runtime_action}}}

    reloaded =
      HotReloadSettings.apply(state, plugin_entry,
        loaded_at_ms: 123,
        reason: :plugin_settings_hot_reload
      )

    status = reloaded.plugin_config.plugins_by_id["plugin-1"]

    assert reloaded.generation == 4
    assert reloaded.registry == state.registry
    assert reloaded.previous_registry == state.registry
    assert reloaded.plugin == status
    assert reloaded.loaded_at_ms == 123
    assert reloaded.reason == :plugin_settings_hot_reload
    assert status.settings == %{"mode" => "fast"}

    assert reloaded.plugin_transitions == [
             HotReloadConfigState.settings_transition(
               HotReloadConfigState.plugin_status(plugin_entry),
               status
             )
           ]
  end

  test "apply preserves previous plugin state and records a settings transition" do
    previous_entry = plugin_entry(%{"mode" => "fast"})
    next_entry = plugin_entry(%{"mode" => "careful"})
    previous_status = HotReloadConfigState.plugin_status(previous_entry)

    state = %{
      generation: 1,
      registry: %{actions: %{}},
      plugin_config: HotReloadConfigState.build([previous_entry])
    }

    reloaded = HotReloadSettings.apply(state, next_entry, loaded_at_ms: 456)
    status = reloaded.plugin_config.plugins_by_id["plugin-1"]

    assert status.settings == %{"mode" => "careful"}
    assert status.enabled? == previous_status.enabled?
    assert status.state == previous_status.state

    assert reloaded.plugin_transitions == [
             HotReloadConfigState.settings_transition(previous_status, status)
           ]
  end

  defp plugin_entry(settings) do
    %ConfigSchema.PluginEntry{
      id: "plugin-1",
      identity: %{"id" => "plugin-1", "version" => "0.1.0"},
      package_identity: %ConfigSchema.PackageIdentity{id: "plugin-1", version: "0.1.0"},
      enabled: true,
      path: "/tmp/plugin-1",
      source: "official",
      provenance: %{},
      entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
      settings: settings,
      trust_policy: %{"tier" => "official", "requires_explicit_approval" => false},
      trust_policy_state: "configured",
      trust_evaluation: %{},
      permissions: %{},
      transports: []
    }
  end
end
