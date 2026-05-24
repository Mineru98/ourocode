defmodule Ourocode.Plugin.ConfigValidationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigValidation

  test "validate_entrypoint_command accepts relative commands without args" do
    assert ConfigValidation.validate_entrypoint_command("bin/plugin", 0) == :ok
  end

  test "validate_entrypoint_command rejects unsafe command shapes with schema messages" do
    assert ConfigValidation.validate_entrypoint_command(" bin/plugin", 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.command must not contain surrounding whitespace"}}

    assert ConfigValidation.validate_entrypoint_command("bin/plugin --stdio", 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.command must not include arguments"}}

    assert ConfigValidation.validate_entrypoint_command("/usr/bin/plugin", 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.command must be a relative command"}}

    assert ConfigValidation.validate_entrypoint_command("../plugin", 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.command must be a relative command inside the plugin"}}
  end

  test "validate_entrypoint_module accepts Elixir module names and rejects other strings" do
    assert ConfigValidation.validate_entrypoint_module("Ourocode.Plugin.Adapter", 0) == :ok

    assert ConfigValidation.validate_entrypoint_module("not a module", 1) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[1].entrypoint.module must be an Elixir module name"}}
  end

  test "validate_entrypoint_path accepts relative paths and rejects absolute or traversing paths" do
    assert ConfigValidation.validate_entrypoint_path("capabilities.json", "entrypoint.path", 0) ==
             :ok

    assert ConfigValidation.validate_entrypoint_path("../capabilities.json", "entrypoint.path", 1) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[1].entrypoint.path must be a relative path inside the plugin"}}

    assert ConfigValidation.validate_entrypoint_path(
             "/tmp/capabilities.json",
             "entrypoint.path",
             1
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[1].entrypoint.path must be a relative path inside the plugin"}}

    assert ConfigValidation.validate_entrypoint_path(
             "capabilities.json\nnext",
             "entrypoint.path",
             1
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[1].entrypoint.path must be a single relative path"}}
  end

  test "path_traverses? detects parent traversal segments only" do
    assert ConfigValidation.path_traverses?("../plugin")
    assert ConfigValidation.path_traverses?("plugins/../plugin")
    refute ConfigValidation.path_traverses?("plugins/..plugin")
    refute ConfigValidation.path_traverses?("plugins/nested/plugin")
  end
end
