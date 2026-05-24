defmodule Ourocode.Plugin.ConfigPluginEntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigPluginEntry

  test "parses one plugin entry with defaults" do
    assert {:ok, entry} =
             ConfigPluginEntry.parse(
               %{
                 "identity" => %{"id" => "demo-plugin", "version" => "1.2.3"},
                 "path" => "plugins/demo",
                 "entrypoint" => %{"type" => "manifest", "path" => "plugin.json"},
                 "permissions" => %{"filesystem" => [], "network" => [], "process" => []}
               },
               0
             )

    assert entry.id == "demo-plugin"
    assert entry.enabled
    assert entry.source == "third_party"
    assert entry.settings == %{}
    assert entry.transports == []
  end

  test "rejects non-map plugin entries" do
    assert ConfigPluginEntry.parse("bad", 2) ==
             {:error, {:invalid_plugin_config_schema, "plugins[2] must be an object"}}
  end

  test "validates duplicate plugin ids" do
    {:ok, first} =
      ConfigPluginEntry.parse(
        %{
          "identity" => %{"id" => "dupe-plugin", "version" => "1.0.0"},
          "path" => "plugins/one",
          "entrypoint" => %{"type" => "manifest", "path" => "plugin.json"},
          "permissions" => %{"filesystem" => [], "network" => [], "process" => []}
        },
        0
      )

    second = %{first | path: "plugins/two"}

    assert ConfigPluginEntry.validate_unique_ids([first, second]) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[1].identity.id duplicates plugins[0].identity.id: dupe-plugin"}}
  end
end
