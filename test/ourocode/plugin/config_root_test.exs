defmodule Ourocode.Plugin.ConfigRootTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigRoot
  alias Ourocode.Plugin.ConfigSchema.PluginEntry

  test "parses plugin entries from the root plugins list" do
    assert {:ok, [%PluginEntry{} = entry]} =
             ConfigRoot.parse(%{
               "plugins" => [
                 %{
                   "identity" => %{"id" => "example-plugin", "version" => "1.0.0"},
                   "path" => "plugins/example",
                   "entrypoint" => %{"type" => "manifest", "path" => "capabilities.json"},
                   "permissions" => %{
                     "filesystem" => [],
                     "network" => [],
                     "process" => []
                   }
                 }
               ]
             })

    assert entry.id == "example-plugin"
    assert entry.path == "plugins/example"
  end

  test "rejects missing or non-list plugin roots" do
    assert ConfigRoot.parse(%{}) ==
             {:error, {:invalid_plugin_config_schema, "plugins list is required"}}

    assert ConfigRoot.parse(%{"plugins" => "bad"}) ==
             {:error, {:invalid_plugin_config_schema, "plugins must be a list"}}
  end

  test "propagates plugin entry validation errors" do
    assert {:error, {:invalid_plugin_config_schema, message}} =
             ConfigRoot.parse(%{"plugins" => [%{}]})

    assert message =~ "plugins[0]"
  end
end
