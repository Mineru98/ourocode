defmodule Ourocode.Runtime.CapabilityGraphTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Runtime.CapabilityGraph

  test "builds a deterministic semantic graph from the command registry" do
    assert {:ok, registry} = Registry.load_builtin()

    graph = CapabilityGraph.build(registry)

    assert graph.summary.count == registry.loaded_count
    assert graph.summary.sources.builtin == registry.loaded_count
    assert graph.summary.origins.builtin == registry.loaded_count

    assert capability = Enum.find(graph.capabilities, &(&1.command == "/capabilities"))
    assert capability.name == "capabilities"
    assert capability.category == :discovery
    assert capability.semantics.mutation_class == :read_only
    assert capability.semantics.parallel_safety == :safe
    assert capability.semantics.scope == :kernel

    assert clear = Enum.find(graph.capabilities, &(&1.command == "/clear"))
    assert clear.semantics.mutation_class == :external_side_effect
    assert clear.semantics.parallel_safety == :serialized
  end

  test "renders a compact grouped capability summary" do
    assert {:ok, registry} = Registry.load_builtin()

    text =
      registry
      |> CapabilityGraph.build()
      |> CapabilityGraph.render_text()

    assert text =~ "capabilities:"
    assert text =~ "builtin="
    assert text =~ "/capabilities"
    assert text =~ "builtin/kernel/read_only/default"
  end
end
