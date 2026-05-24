defmodule Ourocode.Plugin.ConfigStatusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigStatus

  test "report projects parsed plugin config into enabled official and third-party lists" do
    assert {:ok, %ConfigSchema{} = config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.2.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "source": "official",
                   "permissions": {"filesystem": [], "network": [], "process": []}
                 },
                 {
                   "identity": {"id": "vim-mode", "version": "1.4.2"},
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "enabled": false,
                   "source": "third_party",
                   "permissions": {"filesystem": [], "network": [], "process": []}
                 }
               ]
             }
             """)

    assert ConfigStatus.report(config) == %{
             status: :ready,
             plugins: [
               %{
                 plugin_id: "ouroboros-plugin",
                 source_type: "official",
                 version: "0.2.0",
                 enabled?: true,
                 load_state: :load_requested,
                 path: "plugins/ouroboros"
               },
               %{
                 plugin_id: "vim-mode",
                 source_type: "third_party",
                 version: "1.4.2",
                 enabled?: false,
                 load_state: :disabled,
                 path: "plugins/vim-mode"
               }
             ],
             enabled_official_plugins: [
               %{
                 plugin_id: "ouroboros-plugin",
                 source_type: "official",
                 version: "0.2.0",
                 enabled?: true,
                 load_state: :load_requested,
                 path: "plugins/ouroboros"
               }
             ],
             enabled_third_party_plugins: []
           }
  end

  test "record preserves load intent from one plugin entry" do
    assert {:ok, %ConfigSchema{plugins: [plugin]}} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "statusline", "version": "0.3.1"},
                   "path": "plugins/statusline",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": false,
                   "source": "third_party",
                   "permissions": {"filesystem": [], "network": [], "process": []}
                 }
               ]
             }
             """)

    assert ConfigStatus.record(plugin) == %{
             plugin_id: "statusline",
             source_type: "third_party",
             version: "0.3.1",
             enabled?: false,
             load_state: :disabled,
             path: "plugins/statusline"
           }
  end
end
