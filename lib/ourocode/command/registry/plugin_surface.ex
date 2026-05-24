defmodule Ourocode.Command.Registry.PluginSurface do
  @moduledoc """
  Normalizes configured plugin command and skill surfaces into registry entries.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigSchema.PluginEntry
  alias Ourocode.Command.Registry.PluginSurfaceEntry

  @official_ouroboros_plugin_id "ouroboros-plugin"
  @official_ouroboros_namespace "plugin:official:ouroboros"

  @official_ouroboros_commands [
    %{
      "name" => "ooo",
      "slash" => "/ooo",
      "aliases" => ["/ouroboros"],
      "description" => "Run the official Ouroboros workflow surface.",
      "action" => "workflow",
      "args" => [
        %{
          "name" => "goal",
          "required" => false,
          "description" => "Natural-language workflow goal"
        }
      ]
    },
    %{
      "name" => "interview",
      "slash" => "/interview",
      "description" => "Start an official Ouroboros clarification interview.",
      "action" => "interview"
    },
    %{
      "name" => "seed",
      "slash" => "/seed",
      "description" => "Generate an official Ouroboros Seed from an interview.",
      "action" => "seed"
    },
    %{
      "name" => "evolve",
      "slash" => "/evolve",
      "description" => "Run one official Ouroboros evolution step.",
      "action" => "evolve"
    },
    %{
      "name" => "ralph",
      "slash" => "/ralph",
      "description" => "Start the official Ouroboros Ralph convergence loop.",
      "action" => "ralph"
    }
  ]

  @official_ouroboros_skills [
    %{
      "name" => "ouroboros-qa",
      "slash" => "/ouroboros-qa",
      "description" => "Evaluate an artifact with the official Ouroboros QA flow.",
      "mcp_tool" => "ouroboros_qa"
    },
    %{
      "name" => "ouroboros-clarify",
      "slash" => "/ouroboros-clarify",
      "description" =>
        "Clarify vague requirements through the official Ouroboros interview flow.",
      "mcp_tool" => "ouroboros_interview"
    }
  ]

  @official_reserved_slashes MapSet.new(
                               Enum.flat_map(
                                 @official_ouroboros_commands ++ @official_ouroboros_skills,
                                 fn definition ->
                                   [definition["slash"] | Map.get(definition, "aliases", [])]
                                 end
                               )
                             )

  @spec entries(ConfigSchema.t() | [PluginEntry.t()] | nil) :: [map()]
  def entries(nil), do: []

  def entries(%ConfigSchema{plugins: plugins}), do: entries(plugins)

  def entries(plugins) when is_list(plugins) do
    plugins
    |> Enum.flat_map(&normalize_plugin_entries/1)
    |> Enum.sort_by(& &1.slash)
  end

  defp normalize_plugin_entries(%PluginEntry{enabled: false}), do: []

  defp normalize_plugin_entries(%PluginEntry{} = plugin) do
    commands = plugin_surface_definitions(plugin, "commands", @official_ouroboros_commands)
    skills = plugin_surface_definitions(plugin, "skills", @official_ouroboros_skills)

    command_entries =
      Enum.map(commands, fn definition ->
        PluginSurfaceEntry.build!(
          plugin,
          definition,
          :command,
          plugin_command_namespace(plugin),
          plugin_namespace_owner(plugin)
        )
      end)

    skill_entries =
      Enum.map(skills, fn definition ->
        PluginSurfaceEntry.build!(
          plugin,
          definition,
          :skill,
          plugin_command_namespace(plugin),
          plugin_namespace_owner(plugin)
        )
      end)

    command_entries
    |> Kernel.++(skill_entries)
    |> Enum.reject(&reserved_official_namespace_violation?/1)
  end

  defp normalize_plugin_entries(_plugin), do: []

  defp plugin_surface_definitions(%PluginEntry{} = plugin, key, official_defaults) do
    config = plugin.config || %{}

    case PluginSurfaceEntry.field(config, key, false) do
      true ->
        if official_ouroboros_plugin?(plugin), do: official_defaults, else: []

      definitions when is_list(definitions) ->
        definitions

      definitions when is_map(definitions) ->
        definitions
        |> Map.values()
        |> Enum.filter(&is_map/1)

      _disabled_or_invalid ->
        []
    end
  end

  defp official_ouroboros_plugin?(%PluginEntry{
         id: @official_ouroboros_plugin_id,
         source: "official"
       }) do
    true
  end

  defp official_ouroboros_plugin?(_plugin), do: false

  defp plugin_command_namespace(%PluginEntry{} = plugin) do
    if official_ouroboros_plugin?(plugin) do
      @official_ouroboros_namespace
    else
      "plugin:#{plugin.source}:#{plugin.id}"
    end
  end

  defp plugin_namespace_owner(%PluginEntry{} = plugin) do
    if official_ouroboros_plugin?(plugin), do: :official_ouroboros, else: :third_party_plugin
  end

  defp reserved_official_namespace_violation?(%{
         metadata: %{namespace_owner: :official_ouroboros}
       }) do
    false
  end

  defp reserved_official_namespace_violation?(entry) do
    Enum.any?([entry.slash | entry.aliases], &reserved_official_slash?/1)
  end

  defp reserved_official_slash?(slash) do
    MapSet.member?(@official_reserved_slashes, slash) or String.starts_with?(slash, "/ouroboros")
  end
end
