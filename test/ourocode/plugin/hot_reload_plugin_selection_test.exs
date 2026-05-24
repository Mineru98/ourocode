defmodule Ourocode.Plugin.HotReloadPluginSelectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.HotReloadPluginSelection

  test "returns empty config error when no plugins exist and no id is requested" do
    assert HotReloadPluginSelection.select([], nil) == {:error, :plugin_config_empty}
  end

  test "returns not configured when no plugins exist and an id is requested" do
    assert HotReloadPluginSelection.select([], "missing") ==
             {:error, {:plugin_not_configured, "missing"}}
  end

  test "selects the first enabled plugin when no id is requested" do
    disabled = plugin_entry("disabled", enabled: false)
    enabled = plugin_entry("enabled", enabled: true)

    assert HotReloadPluginSelection.select([disabled, enabled], nil) == {:ok, enabled}
  end

  test "falls back to the first plugin when all configured plugins are disabled" do
    first = plugin_entry("first", enabled: false)
    second = plugin_entry("second", enabled: false)

    assert HotReloadPluginSelection.select([first, second], nil) == {:ok, first}
  end

  test "selects a plugin by id regardless of enabled state" do
    first = plugin_entry("first", enabled: true)
    target = plugin_entry("target", enabled: false)

    assert HotReloadPluginSelection.select([first, target], "target") == {:ok, target}
  end

  test "returns not configured for unknown plugin ids" do
    assert HotReloadPluginSelection.select([plugin_entry("known")], "missing") ==
             {:error, {:plugin_not_configured, "missing"}}
  end

  test "maps only configured loader options" do
    plugin =
      plugin_entry("with-loader-opts",
        expected_checksum: "checksum-1",
        manifest_filename: "custom.json"
      )

    assert HotReloadPluginSelection.loader_opts(plugin) == [
             manifest_filename: "custom.json",
             expected_checksum: "checksum-1"
           ]
  end

  test "omits nil loader options" do
    assert HotReloadPluginSelection.loader_opts(plugin_entry("plain")) == []
  end

  defp plugin_entry(id, attrs \\ []) do
    fields =
      [
        id: id,
        identity: %{"id" => id, "version" => "0.1.0"},
        package_identity: %ConfigSchema.PackageIdentity{id: id, version: "0.1.0"},
        path: "/plugins/#{id}",
        entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
        enabled: Keyword.get(attrs, :enabled, true),
        source: "third_party",
        provenance: %{},
        trust_policy: %{},
        trust_policy_state: "absent_defaulted",
        trust_evaluation: %{},
        permissions: %{},
        transports: [],
        expected_checksum: Keyword.get(attrs, :expected_checksum),
        manifest_filename: Keyword.get(attrs, :manifest_filename)
      ]

    struct!(ConfigSchema.PluginEntry, fields)
  end
end
