defmodule Ourocode.Plugin.ConfigFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigFields

  test "required_string accepts non-empty strings and rejects missing or invalid values" do
    assert ConfigFields.required_string(%{"path" => "plugins/demo"}, "path", 2) ==
             {:ok, "plugins/demo"}

    assert ConfigFields.required_string(%{}, "path", 2) ==
             {:error,
              {:invalid_plugin_config_schema, "plugins[2].path must be a non-empty string"}}
  end

  test "optional field readers apply defaults and validate present values" do
    assert ConfigFields.optional_string(%{}, "source", "third_party", 1) ==
             {:ok, "third_party"}

    assert ConfigFields.optional_boolean(%{"enabled" => false}, "enabled", true, 1) ==
             {:ok, false}

    assert ConfigFields.optional_map(%{}, "provenance", %{}, 1) == {:ok, %{}}

    assert ConfigFields.optional_boolean(%{"enabled" => "yes"}, "enabled", true, 1) ==
             {:error, {:invalid_plugin_config_schema, "plugins[1].enabled must be a boolean"}}
  end

  test "validate_source accepts supported sources" do
    for source <- ["official", "third_party", "local", "user"] do
      assert ConfigFields.validate_source(source, 0) == :ok
    end

    assert ConfigFields.validate_source("remote", 0) ==
             {:error, {:invalid_plugin_config_schema, "plugins[0].source is unsupported"}}
  end

  test "parse_settings normalizes object settings and rejects non-objects" do
    assert ConfigFields.parse_settings(%{"settings" => %{"nested" => %{"mode" => "fast"}}}, 3) ==
             {:ok, %{"nested" => %{"mode" => "fast"}}}

    assert ConfigFields.parse_settings(%{}, 3) == {:ok, %{}}

    assert ConfigFields.parse_settings(%{"settings" => []}, 3) ==
             {:error, {:invalid_plugin_config_schema, "plugins[3].settings must be an object"}}
  end
end
