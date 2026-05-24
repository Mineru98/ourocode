defmodule Ourocode.Plugin.ConfigSourceMetadataTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSourceMetadata

  test "parse returns nil when source metadata is absent" do
    assert {:ok, nil} = ConfigSourceMetadata.parse(%{}, 0)
  end

  test "parse validates source metadata field shapes" do
    assert {:error,
            {:invalid_plugin_config_schema, "plugins[1].source_metadata must be an object"}} =
             ConfigSourceMetadata.parse(%{"source_metadata" => []}, 1)

    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[1].source_metadata.id must be a non-empty string"}} =
             ConfigSourceMetadata.parse(%{"source_metadata" => %{"id" => ""}}, 1)

    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[1].source_metadata.provenance must be an object"}} =
             ConfigSourceMetadata.parse(%{"source_metadata" => %{"provenance" => "registry"}}, 1)

    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[1].source_metadata.trust_policy must be an object"}} =
             ConfigSourceMetadata.parse(
               %{"source_metadata" => %{"trust_policy" => "official"}},
               1
             )

    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[1].source_metadata.package_identity must be an object"}} =
             ConfigSourceMetadata.parse(
               %{"source_metadata" => %{"package_identity" => "plugin@1.0.0"}},
               1
             )
  end

  test "validate_id accepts absent and matching source metadata ids" do
    assert :ok = ConfigSourceMetadata.validate_id(nil, "plugin", 0)
    assert :ok = ConfigSourceMetadata.validate_id(%{}, "plugin", 0)
    assert :ok = ConfigSourceMetadata.validate_id(%{"id" => "plugin"}, "plugin", 0)
  end

  test "validate_id rejects mismatched source metadata ids" do
    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[2].source_metadata.id must match identity.id: other-plugin"}} =
             ConfigSourceMetadata.validate_id(%{"id" => "other-plugin"}, "plugin", 2)
  end

  test "apply_defaults copies source metadata into missing top-level fields" do
    plugin = %{"identity" => %{"id" => "plugin"}}

    source_metadata = %{
      "source" => "third_party",
      "provenance" => %{"registry" => "github"},
      "trust_policy" => %{"tier" => "community_code"},
      "package_identity" => %{
        "id" => "plugin",
        "name" => "@community/plugin",
        "version" => "1.2.3",
        "publisher" => "community",
        "namespace" => nil
      }
    }

    assert {:ok, plugin} = ConfigSourceMetadata.apply_defaults(plugin, source_metadata, 0)

    assert plugin["source"] == "third_party"
    assert plugin["provenance"] == %{"registry" => "github"}
    assert plugin["trust_policy"] == %{"tier" => "community_code"}

    assert plugin["package"] == %{
             "name" => "@community/plugin",
             "version" => "1.2.3",
             "publisher" => "community"
           }
  end

  test "apply_defaults accepts matching top-level values" do
    plugin = %{
      "source" => "official",
      "provenance" => %{"distribution" => "bundled"},
      "trust_policy" => %{"tier" => "official"}
    }

    source_metadata = %{
      "source" => "official",
      "provenance" => %{"distribution" => "bundled"},
      "trust_policy" => %{"tier" => "official"}
    }

    assert {:ok, ^plugin} = ConfigSourceMetadata.apply_defaults(plugin, source_metadata, 0)
  end

  test "apply_defaults rejects conflicting top-level metadata" do
    assert {:error,
            {:invalid_plugin_config_schema, "plugins[3].source_metadata.source must match source"}} =
             ConfigSourceMetadata.apply_defaults(
               %{"source" => "local"},
               %{"source" => "third_party"},
               3
             )
  end
end
