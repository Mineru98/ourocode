defmodule Ourocode.Plugin.ConfigPackageIdentityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigPackageIdentity
  alias Ourocode.Plugin.ConfigSchema.PackageIdentity

  test "parse builds package identity from identity and package fields" do
    plugin = %{
      "package" => %{
        "name" => "@team/tool",
        "version" => "1.2.3",
        "publisher" => "team",
        "namespace" => "team"
      }
    }

    identity = %{"id" => "team/tool", "name" => "Tool"}

    assert {:ok,
            %PackageIdentity{
              id: "team/tool",
              name: "Tool",
              version: "1.2.3",
              publisher: "team",
              namespace: "team"
            }} = ConfigPackageIdentity.parse(plugin, identity, 0)
  end

  test "parse rejects missing semantic version and invalid package names" do
    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[0].version is required; set version, identity.version, or package.version to a non-empty string"}} =
             ConfigPackageIdentity.parse(%{}, %{"id" => "team/tool"}, 0)

    assert {:error,
            {:invalid_plugin_config_schema,
             "plugins[0].package.name must use package identity format"}} =
             ConfigPackageIdentity.parse(
               %{"package" => %{"name" => "Bad Name", "version" => "1.0.0"}},
               %{"id" => "team/tool"},
               0
             )
  end

  test "to_package_config drops nil source metadata fields" do
    assert ConfigPackageIdentity.to_package_config(%{
             "name" => "tool",
             "version" => "1.0.0",
             "publisher" => nil,
             "namespace" => "team"
           }) == %{"name" => "tool", "version" => "1.0.0", "namespace" => "team"}
  end
end
