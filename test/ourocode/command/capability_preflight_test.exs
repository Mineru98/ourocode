defmodule Ourocode.Command.CapabilityPreflightTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.CapabilityPreflight
  alias Ourocode.Command.Registry
  alias Ourocode.Command.Registry.PluginSurfaceEntry
  alias Ourocode.Plugin.ConfigSchema.PackageIdentity
  alias Ourocode.Plugin.ConfigSchema.PluginEntry

  test "resolves trusted plugin slash command into a ready read-only preflight" do
    registry = registry_with(plugin_entry(:official), command_definition())

    assert %{
             status: :ready,
             input: "/superpowers-tdd --goal retry",
             capability: %{
               id: "plugin:superpowers:superpowers-tdd",
               name: "superpowers-tdd",
               source: :plugin,
               source_id: "superpowers",
               run_spec: %{
                 kind: :plugin_command,
                 plugin_id: "superpowers",
                 plugin_path: "plugins/superpowers",
                 action: "test_driven_development"
               },
               metadata: %{
                 plugin_id: "superpowers",
                 plugin_source: "official",
                 namespace_owner: :official_ouroboros,
                 command_namespace: "plugin:official:superpowers"
               }
             },
             match: %{token: "/superpowers-tdd", canonical: "/superpowers-tdd", type: :canonical},
             trust: %{
               source: :plugin,
               status: :trusted,
               plugin_id: "superpowers",
               policy_state: "configured",
               policy: %{
                 "tier" => "official",
                 "requires_explicit_approval" => false
               }
             },
             side_effects: %{
               execution: :none,
               discovery: :read_only,
               expected_outputs: [],
               risk_class: "official"
             }
           } = CapabilityPreflight.resolve(registry, "/superpowers-tdd --goal retry")
  end

  test "resolves aliases while preserving the canonical command" do
    registry = registry_with(plugin_entry(:official), command_definition())

    assert %{
             status: :ready,
             match: %{token: "/sp-tdd", canonical: "/superpowers-tdd", type: :alias}
           } = CapabilityPreflight.resolve(registry, "/sp-tdd --goal retry")
  end

  test "resolves bare ooo workflow prefix as the official plugin command" do
    assert {:ok, plugin_config} =
             Ourocode.Plugin.ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "1.0.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": true,
                   "source": "official",
                   "permissions": {"filesystem": [], "network": [], "process": []},
                   "trust_policy": {
                     "tier": "official",
                     "requires_explicit_approval": false
                   },
                   "config": {"commands": true, "skills": true}
                 }
               ]
             }
             """)

    {:ok, registry} =
      Registry.load(bundled_skill_dirs: [], skill_dirs: [], plugin_config: plugin_config)

    assert %{
             status: :ready,
             match: %{token: "/ooo", canonical: "/ooo"},
             capability: %{source: :plugin, source_id: "ouroboros-plugin"}
           } = CapabilityPreflight.resolve(registry, "ooo pm build onboarding")
  end

  test "blocks plugin preflight when explicit trust approval is still required" do
    registry = registry_with(plugin_entry(:community), command_definition())

    assert %{
             status: :blocked,
             reason: :trust_requires_approval,
             trust: %{
               source: :plugin,
               status: :requires_approval,
               plugin_id: "superpowers",
               policy_state: "configured"
             },
             side_effects: %{execution: :none, discovery: :read_only}
           } = CapabilityPreflight.resolve(registry, "/superpowers-tdd --goal retry")
  end

  test "does not guess for natural-language or unknown command input" do
    registry = registry_with(plugin_entry(:official), command_definition())

    assert CapabilityPreflight.resolve(registry, "Use Superpowers TDD") == %{
             status: :missing,
             input: "Use Superpowers TDD",
             reason: :not_command_shaped
           }

    assert CapabilityPreflight.resolve(registry, "/missing") == %{
             status: :missing,
             input: "/missing",
             reason: :unknown_capability
           }
  end

  defp registry_with(plugin, definition) do
    {:ok, registry} = Registry.load_builtin()

    entry =
      PluginSurfaceEntry.build!(
        plugin,
        definition,
        :command,
        "plugin:#{plugin.source}:#{plugin.id}",
        if(plugin.source == "official", do: :official_ouroboros, else: :third_party_plugin)
      )

    {:ok, registry} = Registry.merge_normalized_entries(registry, [entry])
    registry
  end

  defp command_definition do
    %{
      "name" => "superpowers-tdd",
      "slash" => "/superpowers-tdd",
      "aliases" => ["/sp-tdd"],
      "description" => "Run the Superpowers TDD workflow.",
      "action" => "test_driven_development",
      "args" => [%{"name" => "goal", "required" => true}]
    }
  end

  defp plugin_entry(:official) do
    plugin_entry(
      source: "official",
      trust_policy: %{"tier" => "official", "requires_explicit_approval" => false},
      trust_evaluation: %{
        "trusted" => true,
        "trust_classification" => "official"
      }
    )
  end

  defp plugin_entry(:community) do
    plugin_entry(
      source: "third_party",
      trust_policy: %{"tier" => "community_code", "requires_explicit_approval" => true},
      trust_evaluation: %{
        "trusted" => false,
        "trust_classification" => "community_code"
      }
    )
  end

  defp plugin_entry(overrides) do
    struct(
      %PluginEntry{
        id: "superpowers",
        identity: %{"id" => "superpowers", "version" => "1.0.0"},
        package_identity: %PackageIdentity{id: "superpowers", version: "1.0.0"},
        path: "plugins/superpowers",
        entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
        enabled: true,
        source: "official",
        provenance: %{"publisher" => "ouroboros"},
        trust_policy: %{},
        trust_policy_state: "configured",
        trust_evaluation: %{},
        permissions: %{"filesystem" => [], "network" => [], "process" => []},
        transports: [],
        settings: %{},
        metadata: %{},
        config: %{}
      },
      overrides
    )
  end
end
