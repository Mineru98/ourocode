defmodule Ourocode.Command.Registry.PluginSurfaceEntry do
  @moduledoc """
  Builds normalized command registry entries from plugin surface definitions.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigSchema.PluginEntry

  @spec build!(PluginEntry.t(), map(), :command | :skill, String.t(), atom()) :: map()
  def build!(%PluginEntry{} = plugin, definition, surface, command_namespace, namespace_owner) do
    name =
      definition
      |> field("name", field(definition, :name, ""))
      |> unquote_scalar()
      |> slugify_name()

    slash =
      definition
      |> field("slash", name)
      |> normalize_slash()

    aliases =
      definition
      |> field("aliases", [])
      |> List.wrap()
      |> Enum.map(&normalize_slash(to_string(&1)))

    args =
      definition
      |> field("args", [])
      |> List.wrap()
      |> Enum.map(&normalize_arg!/1)

    summary =
      definition
      |> field("description", field(definition, "summary", ""))
      |> to_string()

    run_kind = if surface == :skill, do: :plugin_skill, else: :plugin_command
    mcp_tool = field(definition, "mcp_tool", nil)
    action = field(definition, "action", name)
    source_attribution = source_attribution(plugin, surface, command_namespace, namespace_owner)

    %{
      id: "plugin:#{plugin.id}:#{name}",
      name: name,
      slash: slash,
      source: :plugin,
      source_id: plugin.id,
      source_attribution: source_attribution,
      type: :slash_command,
      category: if(surface == :skill, do: :skills, else: :plugins),
      summary: summary,
      aliases: aliases,
      args: args,
      availability: :available,
      runnable?: true,
      run_spec:
        %{
          kind: run_kind,
          plugin_id: plugin.id,
          plugin_path: plugin.path,
          action: action
        }
        |> maybe_put(:mcp_tool, mcp_tool),
      metadata: %{
        plugin_id: plugin.id,
        plugin_source: plugin.source,
        plugin_surface: surface,
        command_namespace: command_namespace,
        namespace_owner: namespace_owner,
        loaded_from: plugin.path,
        provenance: plugin.provenance,
        trust_policy: plugin.trust_policy,
        trust_evaluation: plugin.trust_evaluation,
        package_identity: ConfigSchema.to_map(plugin)["package_identity"],
        source_attribution: source_attribution
      }
    }
  end

  @spec normalize_slash(String.t()) :: String.t()
  def normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/"), do: command, else: "/#{command}"
  end

  @spec field(map(), atom() | String.t(), term()) :: term()
  def field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, atom_key(key), default))
  end

  defp source_attribution(%PluginEntry{} = plugin, surface, command_namespace, namespace_owner) do
    source_metadata = ConfigSchema.source_metadata(plugin)

    %{
      source: :plugin,
      source_id: plugin.id,
      plugin_id: plugin.id,
      plugin_source: plugin.source,
      plugin_surface: surface,
      command_namespace: command_namespace,
      namespace_owner: namespace_owner,
      loaded_from: plugin.path,
      provenance: source_metadata["provenance"],
      trust_policy: source_metadata["trust_policy"],
      trust_evaluation: source_metadata["trust_evaluation"],
      package_identity: source_metadata["package_identity"]
    }
  end

  defp normalize_arg!(arg) when is_map(arg) do
    %{
      name: arg |> field("name", field(arg, :name, "")) |> to_string(),
      required?: arg |> field("required?", field(arg, "required", false)) |> truthy?(),
      description: arg |> field("description", field(arg, :description, "")) |> to_string()
    }
  end

  defp normalize_arg!(name) when is_binary(name) do
    %{name: name, required?: false, description: ""}
  end

  defp unquote_scalar(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
  end

  defp slugify_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp atom_key(key) when is_atom(key), do: key

  defp atom_key("action"), do: :action
  defp atom_key("aliases"), do: :aliases
  defp atom_key("args"), do: :args
  defp atom_key("commands"), do: :commands
  defp atom_key("description"), do: :description
  defp atom_key("mcp_tool"), do: :mcp_tool
  defp atom_key("name"), do: :name
  defp atom_key("required"), do: :required
  defp atom_key("required?"), do: :required?
  defp atom_key("skills"), do: :skills
  defp atom_key("slash"), do: :slash
  defp atom_key("summary"), do: :summary
  defp atom_key(_key), do: :__missing_plugin_registry_key__

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
