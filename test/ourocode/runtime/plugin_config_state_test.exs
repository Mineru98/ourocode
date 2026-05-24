defmodule Ourocode.Runtime.PluginConfigStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Runtime.PluginConfigState

  test "projects parsed plugin config into runtime registry state" do
    assert {:ok, plugin_config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "enabled-plugin", "version": "1.0.0"},
                   "path": "plugins/enabled",
                   "entrypoint": {"type": "executable", "command": "bin/enabled"},
                   "enabled": true,
                   "source": "third_party",
                   "provenance": {"publisher": "community"},
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

    state = PluginConfigState.from_config(plugin_config)

    assert state.config_loaded? == true
    assert state.enabled_plugins == ["enabled-plugin"]
    assert state.disabled_plugins == ["disabled-plugin"]
    assert Map.keys(state.plugins_by_id) |> Enum.sort() == ["disabled-plugin", "enabled-plugin"]

    assert state.plugins_by_id["enabled-plugin"].state == :enabled
    assert state.plugins_by_id["enabled-plugin"].provenance == %{"publisher" => "community"}

    assert state.load_transitions == [
             %{
               plugin_id: "enabled-plugin",
               from: :configured,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             },
             %{
               plugin_id: "disabled-plugin",
               from: :configured,
               to: :disabled,
               action: :skip_load,
               loadable?: false,
               reason: :disabled_in_config
             }
           ]
  end

  test "projects absent or invalid plugin config into empty registry state" do
    assert PluginConfigState.from_config(nil) == %{
             config_loaded?: false,
             configured_plugins: [],
             enabled_plugins: [],
             disabled_plugins: [],
             plugins_by_id: %{},
             load_transitions: []
           }

    assert PluginConfigState.from_config(:invalid) == PluginConfigState.from_config(nil)
  end
end
