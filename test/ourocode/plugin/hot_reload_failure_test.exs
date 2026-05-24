defmodule Ourocode.Plugin.HotReloadFailureTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.HotReloadConfigState
  alias Ourocode.Plugin.HotReloadFailure
  alias Ourocode.Plugin.LoadError

  test "failure projects structured LoadError details" do
    error = %LoadError{
      reason: :checksum_mismatch,
      message: "checksum mismatch",
      plugin_path: "plugins/demo",
      manifest_path: "plugins/demo/capabilities.json"
    }

    assert HotReloadFailure.failure(plugin_entry(), error, loaded_at_ms: 12_345) == %{
             plugin_id: "demo-plugin",
             state: :load_failed,
             reason: :checksum_mismatch,
             message: "checksum mismatch",
             plugin_path: "plugins/demo",
             manifest_path: "plugins/demo/capabilities.json",
             source: "third_party",
             trust_policy: %{"tier" => "community_code"},
             attempted_at_ms: 12_345
           }
  end

  test "apply_failure updates config state, transition state, and failure list" do
    plugin = plugin_entry()
    config_state = HotReloadConfigState.build([plugin])
    transitions = [%{plugin_id: plugin.id, from: :enabled, to: :enabled, action: :none}]

    state = %{
      generation: 2,
      registry: %{actions: %{}},
      plugin_config: config_state,
      plugin_transitions: transitions,
      plugin_load_failures: [%{plugin_id: "other"}]
    }

    failed =
      HotReloadFailure.apply_failure(
        state,
        plugin,
        :boom,
        transitions,
        2,
        %{actions: %{}},
        loaded_at_ms: 99
      )

    assert failed.generation == 3
    assert failed.reason == :plugin_config_load_failed
    assert failed.plugin.state == :load_failed
    assert failed.plugin.load_error.reason == :boom
    assert [failure, %{plugin_id: "other"}] = failed.plugin_load_failures
    assert failure.plugin_id == plugin.id
    assert failed.plugin_config.plugins_by_id[plugin.id].state == :load_failed
    assert [%{plugin_id: "demo-plugin", action: :load_failed}] = failed.plugin_transitions
  end

  test "clear removes matching active load failures only" do
    state = %{
      plugin_load_failures: [
        %{plugin_id: "demo-plugin"},
        %{plugin_id: "other-plugin"}
      ]
    }

    assert HotReloadFailure.clear(state, "demo-plugin").plugin_load_failures == [
             %{plugin_id: "other-plugin"}
           ]
  end

  defp plugin_entry do
    %ConfigSchema.PluginEntry{
      id: "demo-plugin",
      identity: %{"id" => "demo-plugin"},
      package_identity: %ConfigSchema.PackageIdentity{id: "demo-plugin", version: "1.0.0"},
      path: "plugins/demo",
      entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
      enabled: true,
      source: "third_party",
      provenance: %{},
      trust_policy: %{"tier" => "community_code"},
      trust_policy_state: "configured",
      trust_evaluation: %{},
      permissions: %{},
      transports: []
    }
  end
end
