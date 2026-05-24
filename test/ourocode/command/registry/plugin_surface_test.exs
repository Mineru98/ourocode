defmodule Ourocode.Command.Registry.PluginSurfaceTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.PluginSurface
  alias Ourocode.Plugin.ConfigSchema.PluginEntry
  alias Ourocode.Plugin.ConfigSchema.PackageIdentity

  test "entries normalize third-party plugin command and skill definitions" do
    plugin = plugin_entry()

    assert [skill, command] = PluginSurface.entries([plugin])
    assert Enum.map([skill, command], & &1.slash) == ["/vim-help", "/vim-toggle"]

    assert command.source == :plugin
    assert command.category == :plugins

    assert command.run_spec == %{
             kind: :plugin_command,
             plugin_id: "vim-mode",
             plugin_path: "plugins/vim-mode",
             action: "toggle_mode"
           }

    assert command.args == [%{name: "mode", required?: true, description: "Mode to activate"}]
    assert command.source_attribution.command_namespace == "plugin:third_party:vim-mode"
    assert command.source_attribution.namespace_owner == :third_party_plugin

    assert skill.category == :skills
    assert skill.run_spec.mcp_tool == "vim_help"
  end

  test "entries reject third-party attempts to claim official ouroboros slashes" do
    plugin =
      plugin_entry(%{
        config: %{
          "commands" => [
            %{"name" => "fake", "slash" => "/ouroboros", "description" => "Fake official"}
          ],
          "skills" => [
            %{"name" => "fake-qa", "slash" => "/ouroboros-qa", "description" => "Fake qa"}
          ]
        }
      })

    assert PluginSurface.entries([plugin]) == []
  end

  defp plugin_entry(overrides \\ %{}) do
    base = %PluginEntry{
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
      config: %{
        "commands" => [
          %{
            "name" => "vim-toggle",
            "description" => "Toggle vim-like terminal controls.",
            "aliases" => ["/vim"],
            "action" => "toggle_mode",
            "args" => [
              %{"name" => "mode", "required" => true, "description" => "Mode to activate"}
            ]
          }
        ],
        "skills" => [
          %{
            "name" => "vim-help",
            "description" => "Show plugin-provided vim guidance.",
            "mcp_tool" => "vim_help"
          }
        ]
      }
    }

    struct(base, overrides)
  end
end
