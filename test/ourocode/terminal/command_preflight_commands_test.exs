defmodule Ourocode.Terminal.CommandPreflightCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Command.Registry.PluginSurfaceEntry
  alias Ourocode.Plugin.ConfigSchema.PackageIdentity
  alias Ourocode.Plugin.ConfigSchema.PluginEntry
  alias Ourocode.Terminal.CommandPreflightCommands

  test "renders trusted plugin capability preflight without execution" do
    {:ok, output} = StringIO.open("")
    registry = registry_with_plugin()

    assert {:ok, %{preflight: %{status: :ready}}} =
             CommandPreflightCommands.render(
               :show_preflight,
               %{args: ["/superpowers-tdd", "--goal", "retry"]},
               %{output: output},
               registry
             )

    {_input, text} = StringIO.contents(output)

    assert text =~ "preflight: ready"
    assert text =~ "command: /superpowers-tdd"
    assert text =~ "action: test driven development"
    assert text =~ "status: ready; trusted plugin"
    assert text =~ "execution: preview only"
    assert text =~ "ready: Enter runs the reviewed command"
    refute text =~ "plugin_path"
    refute text =~ "plugin_id"
    refute text =~ "risk:"
    refute text =~ "source:"
  end

  test "renders missing preflight for non command-shaped input" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{preflight: %{status: :missing, reason: :not_command_shaped}}} =
             CommandPreflightCommands.render(
               :show_preflight,
               %{args: ["Use", "Superpowers"]},
               %{output: output},
               registry_with_plugin()
             )

    {_input, text} = StringIO.contents(output)

    assert text =~ "preflight: missing"
    assert text =~ "reason: not_command_shaped"
  end

  test "renders auto workflow preflight as approval gated" do
    {:ok, output} = StringIO.open("")

    assert {:ok, %{preflight: %{status: :ready}}} =
             CommandPreflightCommands.render(
               :show_preflight,
               %{args: ["ooo", "auto", "improve", "startup"]},
               %{output: output},
               registry_with_ouroboros_plugin()
             )

    {_input, text} = StringIO.contents(output)

    assert text =~ "preflight: ready"
    assert text =~ "command: ooo auto improve startup"
    assert text =~ "action: start guided work"
    assert text =~ "execution: approval-gated workflow; no files change during preflight"
    refute text =~ "execution: preview only"
  end

  defp registry_with_plugin do
    {:ok, registry} = Registry.load_builtin()

    entry =
      PluginSurfaceEntry.build!(
        plugin_entry(),
        %{
          "name" => "superpowers-tdd",
          "slash" => "/superpowers-tdd",
          "description" => "Run the Superpowers TDD workflow.",
          "action" => "test_driven_development"
        },
        :command,
        "plugin:official:superpowers",
        :official_ouroboros
      )

    {:ok, registry} = Registry.merge_normalized_entries(registry, [entry])
    registry
  end

  defp registry_with_ouroboros_plugin do
    {:ok, registry} = Registry.load_builtin()

    entry =
      PluginSurfaceEntry.build!(
        ouroboros_plugin_entry(),
        %{
          "name" => "ooo",
          "slash" => "/ooo",
          "aliases" => ["/ouroboros"],
          "description" => "Run the official Ouroboros workflow surface.",
          "action" => "workflow"
        },
        :command,
        "plugin:official:ouroboros",
        :official_ouroboros
      )

    {:ok, registry} = Registry.merge_normalized_entries(registry, [entry])
    registry
  end

  defp plugin_entry do
    %PluginEntry{
      id: "superpowers",
      identity: %{"id" => "superpowers", "version" => "1.0.0"},
      package_identity: %PackageIdentity{id: "superpowers", version: "1.0.0"},
      path: "plugins/superpowers",
      entrypoint: %{"type" => "manifest", "path" => "capabilities.json"},
      enabled: true,
      source: "official",
      provenance: %{"publisher" => "ouroboros"},
      trust_policy: %{"tier" => "official", "requires_explicit_approval" => false},
      trust_policy_state: "configured",
      trust_evaluation: %{"trusted" => true, "trust_classification" => "official"},
      permissions: %{"filesystem" => [], "network" => [], "process" => []},
      transports: [],
      settings: %{},
      metadata: %{},
      config: %{}
    }
  end

  defp ouroboros_plugin_entry do
    %{plugin_entry() | id: "ouroboros-plugin", source: "official"}
  end
end
