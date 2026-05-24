defmodule Ourocode.Plugin.ConfigSettingsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSettings

  test "normalizes nested JSON-safe settings" do
    settings = %{
      "string" => "value",
      "number" => 1,
      "boolean" => true,
      "nil" => nil,
      "list" => ["a", 2, false, %{"nested" => "ok"}],
      "object" => %{"child" => %{"enabled" => true}}
    }

    assert ConfigSettings.normalize(settings, "plugins[0].settings") == {:ok, settings}
  end

  test "rejects invalid setting keys and values with schema-shaped errors" do
    assert ConfigSettings.normalize(%{"" => "value"}, "plugins[0].settings") ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[0].settings keys must be non-empty strings"}}

    assert ConfigSettings.normalize(%{"bad" => {:tuple}}, "plugins[0].settings") ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[0].settings.bad must be a JSON-safe setting value: string, number, boolean, null, list, or object"}}

    assert ConfigSettings.normalize(
             %{"palette" => %{"invalid" => %{"" => "blank nested key"}}},
             "plugins[0].settings"
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[0].settings.palette.invalid keys must be non-empty strings"}}
  end
end
