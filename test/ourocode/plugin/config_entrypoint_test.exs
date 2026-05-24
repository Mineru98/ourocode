defmodule Ourocode.Plugin.ConfigEntrypointTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigEntrypoint

  test "parse accepts manifest entrypoints" do
    entrypoint = %{"type" => "manifest", "path" => "capabilities.json"}

    assert ConfigEntrypoint.parse(%{"entrypoint" => entrypoint}, 0) == {:ok, entrypoint}
  end

  test "parse accepts executable entrypoints" do
    entrypoint = %{"type" => "executable", "command" => "bin/plugin"}

    assert ConfigEntrypoint.parse(%{"entrypoint" => entrypoint}, 0) == {:ok, entrypoint}
  end

  test "parse accepts elixir module entrypoints" do
    entrypoint = %{"type" => "elixir_module", "module" => "Ourocode.Plugin.Adapter"}

    assert ConfigEntrypoint.parse(%{"entrypoint" => entrypoint}, 0) == {:ok, entrypoint}
  end

  test "parse rejects missing or unsupported entrypoints" do
    assert ConfigEntrypoint.parse(%{}, 1) ==
             {:error, {:invalid_plugin_config_schema, "plugins[1].entrypoint must be an object"}}

    assert ConfigEntrypoint.parse(%{"entrypoint" => %{"type" => "python"}}, 1) ==
             {:error,
              {:invalid_plugin_config_schema, "plugins[1].entrypoint.type is unsupported: python"}}
  end

  test "parse rejects invalid target fields with schema messages" do
    assert ConfigEntrypoint.parse(%{"entrypoint" => %{"type" => "manifest"}}, 2) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.path must be a non-empty string"}}

    assert ConfigEntrypoint.parse(
             %{"entrypoint" => %{"type" => "executable", "command" => "bin/plugin --stdio"}},
             2
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.command must not include arguments"}}

    assert ConfigEntrypoint.parse(
             %{"entrypoint" => %{"type" => "elixir_module", "module" => "not a module"}},
             2
           ) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[2].entrypoint.module must be an Elixir module name"}}
  end
end
