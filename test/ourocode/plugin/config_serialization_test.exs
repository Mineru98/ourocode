defmodule Ourocode.Plugin.ConfigSerializationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigSerialization

  test "to_map projects config and plugin entries with source metadata" do
    entry = plugin_entry()
    config = %ConfigSchema{plugins: [entry]}

    assert %{"plugins" => [serialized]} = ConfigSerialization.to_map(config)
    assert serialized == ConfigSerialization.to_map(entry)

    assert serialized["source_metadata"] == %{
             "id" => "plugin-one",
             "source" => "third_party",
             "provenance" => %{"publisher" => "acme"},
             "trust_policy" => %{"tier" => "community_code"},
             "trust_evaluation" => %{"trusted" => true},
             "package_identity" => %{
               "id" => "plugin-one",
               "name" => "Plugin One",
               "version" => "1.0.0",
               "publisher" => nil,
               "namespace" => nil,
               "package" => nil
             }
           }
  end

  test "to_map omits nil loader-only fields and keeps configured loader fields" do
    base =
      ConfigSerialization.to_map(plugin_entry(expected_checksum: nil, manifest_filename: nil))

    refute Map.has_key?(base, "expected_checksum")
    refute Map.has_key?(base, "manifest_filename")
    refute Map.has_key?(base, "config")

    serialized =
      ConfigSerialization.to_map(
        plugin_entry(
          expected_checksum: "abc123",
          manifest_filename: "capabilities.json",
          config: %{"raw" => true}
        )
      )

    assert serialized["expected_checksum"] == "abc123"
    assert serialized["manifest_filename"] == "capabilities.json"
    assert serialized["config"] == %{"raw" => true}
  end

  defp plugin_entry(overrides \\ []) do
    struct(
      %ConfigSchema.PluginEntry{
        id: "plugin-one",
        identity: %{"id" => "plugin-one", "name" => "Plugin One"},
        package_identity: %ConfigSchema.PackageIdentity{
          id: "plugin-one",
          name: "Plugin One",
          version: "1.0.0"
        },
        path: "plugins/plugin-one",
        entrypoint: %{"type" => "elixir_module", "module" => "PluginOne"},
        enabled: true,
        source: "third_party",
        provenance: %{"publisher" => "acme"},
        trust_policy: %{"tier" => "community_code"},
        trust_policy_state: "configured",
        trust_evaluation: %{"trusted" => true},
        permissions: %{"filesystem" => []},
        transports: [],
        settings: %{},
        metadata: %{}
      },
      overrides
    )
  end
end
