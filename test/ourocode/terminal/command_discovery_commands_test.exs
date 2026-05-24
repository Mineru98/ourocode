defmodule Ourocode.Terminal.CommandDiscoveryCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.CommandDiscoveryCommands

  setup do
    {:ok, registry} = Registry.load_builtin()
    {:ok, output} = StringIO.open("")

    %{registry: registry, output: output, state: %{output: output}}
  end

  test "handles discovery actions only" do
    assert CommandDiscoveryCommands.handles?(:show_help)
    assert CommandDiscoveryCommands.handles?(:show_commands)
    assert CommandDiscoveryCommands.handles?(:show_skills)
    assert CommandDiscoveryCommands.handles?(:show_capabilities)
    refute CommandDiscoveryCommands.handles?(:show_status)
    refute CommandDiscoveryCommands.handles?(:unknown)
  end

  test "render help and commands list all registry entries", %{
    registry: registry,
    state: state,
    output: output
  } do
    assert {:ok, %{count: help_count}} =
             CommandDiscoveryCommands.render(:show_help, state, registry)

    assert {:ok, %{count: commands_count}} =
             CommandDiscoveryCommands.render(:show_commands, state, registry)

    assert help_count == length(Registry.entries(registry))
    assert commands_count == help_count

    {_input, text} = StringIO.contents(output)
    assert text =~ "commands:"
    assert text =~ "/help [builtin/discovery]"
    assert text =~ "/capabilities"
  end

  test "render_registry renders entries and returns count", %{
    registry: registry,
    output: output
  } do
    assert {:ok, %{count: count}} =
             CommandDiscoveryCommands.render_registry(output, registry, :all)

    assert count == length(Registry.entries(registry))

    {_input, text} = StringIO.contents(output)
    assert text =~ "commands:"
    assert text =~ "/help [builtin/discovery]"
  end

  test "render skills filters skill-capable registry sources", %{
    registry: registry,
    state: state,
    output: output
  } do
    assert {:ok, %{count: count}} =
             CommandDiscoveryCommands.render(:show_skills, state, registry)

    {_input, text} = StringIO.contents(output)

    assert count >= 0
    assert text =~ "commands:"
    refute text =~ "/help [builtin/discovery]"
  end

  test "render capabilities shows capability graph", %{
    registry: registry,
    state: state,
    output: output
  } do
    assert {:ok, %{count: count, graph: graph}} =
             CommandDiscoveryCommands.render(:show_capabilities, state, registry)

    {_input, text} = StringIO.contents(output)

    assert count == graph.summary.count
    assert text =~ "capabilities:"
    assert text =~ "/help"
  end
end
