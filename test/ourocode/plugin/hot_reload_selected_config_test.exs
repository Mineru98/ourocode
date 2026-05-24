defmodule Ourocode.Plugin.HotReloadSelectedConfigTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.HotReloadBoundary
  alias Ourocode.Plugin.HotReloadSelectedConfig

  test "applies settings-only reload without invoking plugin loader" do
    plugins = [
      plugin_entry("plugin-a", enabled: true, settings: %{"mode" => "fast"})
    ]

    state = HotReloadBoundary.new(%{actions: %{{:session, :open} => :base_action}})

    assert {:ok, reloaded} =
             HotReloadSelectedConfig.apply(
               state,
               plugins,
               [settings_only: true, loaded_at_ms: 123],
               fn _state, _path, _opts -> flunk("settings-only reload should not load plugin") end
             )

    assert reloaded.generation == 1
    assert reloaded.registry == reloaded.previous_registry
    assert reloaded.plugin.id == "plugin-a"
    assert reloaded.plugin.settings == %{"mode" => "fast"}
    assert reloaded.loaded_at_ms == 123
    assert reloaded.reason == :plugin_settings_hot_reload
  end

  test "disabled plugin restores base registry and records disabled transition" do
    plugins = [plugin_entry("plugin-a", enabled: false)]

    state =
      HotReloadBoundary.new(%{actions: %{{:session, :open} => :base_action}})
      |> Map.put(:registry, %{actions: %{{:session, :open} => :base_action, extra: :plugin}})

    assert {:ok, reloaded} =
             HotReloadSelectedConfig.apply(state, plugins, [loaded_at_ms: 456], fn
               _state, _path, _opts -> flunk("disabled plugin should not load")
             end)

    assert reloaded.generation == 1
    assert reloaded.registry.actions == %{{:session, :open} => :base_action}
    assert reloaded.plugin.state == :disabled
    assert reloaded.plugin_config.disabled_plugins == ["plugin-a"]

    assert reloaded.plugin_transitions == [
             %{
               plugin_id: "plugin-a",
               from: :unconfigured,
               to: :disabled,
               action: :skip_load,
               loadable?: false,
               reason: :disabled_in_config
             }
           ]
  end

  test "enabled plugin delegates loading and preserves config state" do
    plugins = [plugin_entry("plugin-a", enabled: true)]
    state = HotReloadBoundary.new(%{actions: %{}})

    reload_fun = fn state_with_config, path, opts ->
      assert path == "/tmp/plugin-a"
      assert Keyword.fetch!(opts, :reason) == :plugin_config_hot_reload
      assert state_with_config.plugin_config.enabled_plugins == ["plugin-a"]

      {:ok,
       state_with_config
       |> Map.put(:generation, 1)
       |> Map.put(:registry, %{actions: %{loaded: :action}})
       |> Map.put(:plugin, %{id: "plugin-a", state: :enabled})}
    end

    assert {:ok, reloaded} =
             HotReloadSelectedConfig.apply(state, plugins, [loaded_at_ms: 789], reload_fun)

    assert reloaded.registry.actions == %{loaded: :action}
    assert reloaded.plugin_config.enabled_plugins == ["plugin-a"]

    assert reloaded.plugin_transitions == [
             %{
               plugin_id: "plugin-a",
               from: :unconfigured,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             }
           ]
  end

  test "load failure is captured as structured plugin state" do
    plugins = [plugin_entry("plugin-a", enabled: true)]
    state = HotReloadBoundary.new(%{actions: %{base: :action}})

    assert {:ok, reloaded} =
             HotReloadSelectedConfig.apply(state, plugins, [loaded_at_ms: 999], fn
               _state, _path, _opts -> {:error, :boom}
             end)

    assert reloaded.generation == 1
    assert reloaded.registry.actions == %{base: :action}
    assert reloaded.reason == :plugin_config_load_failed
    assert reloaded.plugin.state == :load_failed
    assert reloaded.plugin.load_error.reason == :boom
    assert reloaded.plugin_config.failed_plugins == ["plugin-a"]
    assert [failure] = reloaded.plugin_load_failures

    assert hd(reloaded.plugin_transitions).load_error == failure
  end

  defp plugin_entry(id, opts) do
    %ConfigSchema.PluginEntry{
      id: id,
      identity: %{"id" => id, "version" => "0.1.0"},
      package_identity: %ConfigSchema.PackageIdentity{id: id, version: "0.1.0"},
      path: "/tmp/#{id}",
      entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
      manifest_filename: "capabilities.json",
      enabled: Keyword.fetch!(opts, :enabled),
      source: "official",
      provenance: %{},
      expected_checksum: Keyword.get(opts, :expected_checksum),
      permissions: %{},
      transports: [],
      trust_policy: %{"tier" => "official", "requires_explicit_approval" => false},
      trust_policy_state: "explicit",
      trust_evaluation: %{},
      settings: Keyword.get(opts, :settings, %{})
    }
  end
end
