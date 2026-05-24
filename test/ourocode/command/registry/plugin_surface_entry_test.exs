defmodule Ourocode.Command.Registry.PluginSurfaceEntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.PluginSurfaceEntry
  alias Ourocode.Plugin.ConfigSchema.PackageIdentity
  alias Ourocode.Plugin.ConfigSchema.PluginEntry

  test "builds normalized plugin command entries from mixed atom and string definitions" do
    plugin = plugin_entry()

    entry =
      PluginSurfaceEntry.build!(
        plugin,
        %{
          :name => "\"Fancy Toggle!\"",
          "aliases" => ["toggle", "/vim"],
          "summary" => "Toggle mode.",
          :action => "toggle_mode",
          :args => [
            %{name: "mode", required?: "true", description: "Mode to activate"},
            "scope"
          ]
        },
        :command,
        "plugin:third_party:vim-mode",
        :third_party_plugin
      )

    assert entry.id == "plugin:vim-mode:fancy-toggle"
    assert entry.name == "fancy-toggle"
    assert entry.slash == "/fancy-toggle"
    assert entry.aliases == ["/toggle", "/vim"]
    assert entry.category == :plugins

    assert entry.args == [
             %{name: "mode", required?: true, description: "Mode to activate"},
             %{name: "scope", required?: false, description: ""}
           ]

    assert entry.run_spec == %{
             kind: :plugin_command,
             plugin_id: "vim-mode",
             plugin_path: "plugins/vim-mode",
             action: "toggle_mode"
           }

    assert entry.source_attribution.command_namespace == "plugin:third_party:vim-mode"
    assert entry.source_attribution.namespace_owner == :third_party_plugin
    assert entry.metadata.source_attribution == entry.source_attribution
  end

  test "builds plugin skill entries with mcp tool metadata" do
    plugin = plugin_entry()

    entry =
      PluginSurfaceEntry.build!(
        plugin,
        %{"name" => "vim-help", "mcp_tool" => "vim_help"},
        :skill,
        "plugin:third_party:vim-mode",
        :third_party_plugin
      )

    assert entry.category == :skills
    assert entry.run_spec.kind == :plugin_skill
    assert entry.run_spec.action == "vim-help"
    assert entry.run_spec.mcp_tool == "vim_help"
  end

  test "normalizes slash strings and map fields" do
    assert PluginSurfaceEntry.normalize_slash("foo") == "/foo"
    assert PluginSurfaceEntry.normalize_slash(" /bar ") == "/bar"

    assert PluginSurfaceEntry.field(%{"name" => "string", name: "atom"}, "name", "default") ==
             "string"

    assert PluginSurfaceEntry.field(%{name: "atom"}, "name", "default") == "atom"
    assert PluginSurfaceEntry.field(%{}, "name", "default") == "default"
  end

  defp plugin_entry do
    %PluginEntry{
      id: "vim-mode",
      identity: %{"id" => "vim-mode", "version" => "1.0.0"},
      package_identity: %PackageIdentity{id: "vim-mode", version: "1.0.0"},
      path: "plugins/vim-mode",
      entrypoint: %{"type" => "executable", "command" => "bin/vim-mode"},
      enabled: true,
      source: "third_party",
      provenance: %{"publisher" => "community"},
      trust_policy: %{"tier" => "community_code"},
      trust_policy_state: "configured",
      trust_evaluation: %{"classification" => "community_code"},
      permissions: %{"filesystem" => [], "network" => [], "process" => []},
      transports: [],
      settings: %{},
      metadata: %{},
      config: %{}
    }
  end
end
