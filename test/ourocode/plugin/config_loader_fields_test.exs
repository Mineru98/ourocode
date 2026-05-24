defmodule Ourocode.Plugin.ConfigLoaderFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigLoaderFields

  test "parse returns default metadata and omits absent loader fields" do
    assert ConfigLoaderFields.parse(%{}, 0) == {:ok, %{metadata: %{}}}
  end

  test "parse preserves optional loader fields and metadata" do
    plugin = %{
      "expected_checksum" => "abc123",
      "manifest_filename" => "capabilities.json",
      "metadata" => %{
        "description" => "Terminal workflow plugin",
        "priority" => 1,
        "enabled" => true,
        "homepage" => nil,
        "tags" => ["workflow", "terminal"]
      },
      "config" => %{"commands" => true}
    }

    assert ConfigLoaderFields.parse(plugin, 1) ==
             {:ok,
              %{
                expected_checksum: "abc123",
                manifest_filename: "capabilities.json",
                metadata: %{
                  "description" => "Terminal workflow plugin",
                  "priority" => 1,
                  "enabled" => true,
                  "homepage" => nil,
                  "tags" => ["workflow", "terminal"]
                },
                config: %{"commands" => true}
              }}
  end

  test "parse rejects invalid optional loader field shapes" do
    assert ConfigLoaderFields.parse(%{"expected_checksum" => ""}, 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].expected_checksum must be a non-empty string"}}

    assert ConfigLoaderFields.parse(%{"manifest_filename" => 10}, 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].manifest_filename must be a non-empty string"}}

    assert ConfigLoaderFields.parse(%{"config" => []}, 2) ==
             {:error, {:invalid_plugin_config_schema, "plugins[2].config must be an object"}}
  end

  test "parse rejects invalid metadata keys and values" do
    assert ConfigLoaderFields.parse(%{"metadata" => %{"" => "empty"}}, 3) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[3].metadata keys must be non-empty strings"}}

    assert ConfigLoaderFields.parse(%{"metadata" => %{"author" => %{}}}, 3) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[3].metadata.author must be a string, number, boolean, null, or list of strings"}}

    assert ConfigLoaderFields.parse(%{"metadata" => %{"tags" => ["workflow", ""]}}, 3) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[3].metadata.tags must be a string, number, boolean, null, or list of strings"}}
  end
end
