defmodule Ourocode.Terminal.CommandDiscoveryCommands do
  @moduledoc """
  Read-only slash-command renderers for command discovery.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Runtime.CapabilityGraph

  @actions [:show_help, :show_commands, :show_skills, :show_capabilities]

  @type action :: :show_help | :show_commands | :show_skills | :show_capabilities

  @spec handles?(term()) :: boolean()
  def handles?(action), do: action in @actions

  @spec render(action(), map(), map()) :: {:ok, map()}
  def render(action, state, registry) when action in [:show_help, :show_commands] do
    render_registry(state.output, registry, :all)
  end

  def render(:show_skills, state, registry) do
    render_registry(state.output, registry, :skills)
  end

  def render(:show_capabilities, state, registry) do
    render_capability_graph(state.output, registry)
  end

  @spec render_capability_graph(pid(), map()) :: {:ok, map()}
  def render_capability_graph(output, registry) when is_map(registry) do
    graph = CapabilityGraph.build(registry)
    IO.puts(output, CapabilityGraph.render_text(graph))
    {:ok, %{count: graph.summary.count, graph: graph}}
  end

  @spec render_registry(pid(), map(), :all | :skills) :: {:ok, map()}
  def render_registry(output, registry, filter) when is_map(registry) do
    entries =
      case filter do
        :skills ->
          CommandRegistry.query(registry,
            sources: [:local, :bundled_skill, :plugin, :dynamic_skill]
          )

        :all ->
          CommandRegistry.entries(registry)
      end

    IO.puts(output, "commands:")

    Enum.each(entries, fn entry ->
      IO.puts(output, "  #{entry.slash} [#{entry.source}/#{entry.category}] #{entry.summary}")
    end)

    {:ok, %{count: length(entries)}}
  end
end
