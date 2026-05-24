defmodule Ourocode.Plugin.ConfigPermissionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigPermissions

  test "parse accepts required permission lists" do
    permissions = %{
      "filesystem" => ["workspace:read"],
      "network" => ["api.example.com"],
      "process" => ["bin/plugin"]
    }

    assert ConfigPermissions.parse(%{"permissions" => permissions}, 0) == {:ok, permissions}
  end

  test "parse rejects missing or non-object permissions" do
    assert ConfigPermissions.parse(%{}, 1) ==
             {:error, {:invalid_plugin_config_schema, "plugins[1].permissions must be an object"}}

    assert ConfigPermissions.parse(%{"permissions" => []}, 1) ==
             {:error, {:invalid_plugin_config_schema, "plugins[1].permissions must be an object"}}
  end

  test "parse requires filesystem network and process fields" do
    assert ConfigPermissions.parse(
             %{"permissions" => %{"filesystem" => [], "network" => []}},
             2
           ) ==
             {:error,
              {:invalid_plugin_config_schema, "plugins[2].permissions.process is required"}}
  end

  test "parse rejects invalid permission values" do
    for {field, value} <- [
          {"filesystem", [" workspace:read"]},
          {"network", ["api.example.com\nnext"]},
          {"process", [""]},
          {"process", "bin/plugin"}
        ] do
      permissions =
        %{
          "filesystem" => [],
          "network" => [],
          "process" => []
        }
        |> Map.put(field, value)

      assert ConfigPermissions.parse(%{"permissions" => permissions}, 3) ==
               {:error,
                {:invalid_plugin_config_schema,
                 "plugins[3].permissions.#{field} must be a list of non-empty strings"}}
    end
  end
end
