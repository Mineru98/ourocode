defmodule Ourocode.Command.RegistryEntryAdapter do
  @moduledoc """
  Normalization adapters for command registry entries.

  Slash-command definitions and skill definitions arrive from different
  discovery paths, but the terminal input layer consumes one registry entry
  shape. This module keeps that conversion explicit and reusable.
  """

  @type source :: :builtin | :bundled_skill | :local | :plugin | :mcp | :dynamic_skill

  @doc """
  Converts a slash command definition into the shared registry entry shape.
  """
  @spec from_slash_command!(map(), keyword()) :: map()
  def from_slash_command!(definition, opts \\ []) when is_map(definition) and is_list(opts) do
    source = Keyword.get(opts, :source, :builtin)
    source_id = Keyword.get(opts, :source_id, source |> to_string())
    distribution = Keyword.get(opts, :distribution, source)
    run_spec = Keyword.get(opts, :run_spec, field(definition, "run_spec", %{}))

    name =
      definition
      |> field("name", "")
      |> to_string()
      |> slugify_name()

    slash =
      definition
      |> field("slash", name)
      |> normalize_slash()

    source_attribution =
      Keyword.get(opts, :source_attribution, %{
        source: source,
        source_id: source_id,
        distribution: distribution
      })

    %{
      id: Keyword.get(opts, :id, "#{source}:#{slash}"),
      name: name,
      slash: slash,
      source: source,
      source_id: source_id,
      source_attribution: source_attribution,
      type: :slash_command,
      category: Keyword.get(opts, :category, field(definition, "category", :commands)),
      summary:
        definition |> field("summary", field(definition, "description", "")) |> to_string(),
      aliases: normalize_aliases(field(definition, "aliases", [])),
      args: normalize_args(field(definition, "args", [])),
      availability: Keyword.get(opts, :availability, :available),
      runnable?: Keyword.get(opts, :runnable?, true),
      run_spec: run_spec,
      metadata:
        Map.merge(Keyword.get(opts, :metadata, %{}), %{source_attribution: source_attribution})
    }
  end

  @doc """
  Converts a skill definition into the shared registry entry shape.
  """
  @spec from_skill_definition!(map(), keyword()) :: map()
  def from_skill_definition!(definition, opts \\ []) when is_map(definition) and is_list(opts) do
    source = Keyword.get(opts, :source, :local)

    source_id =
      Keyword.get(opts, :source_id, field(definition, "source_id", source |> to_string()))

    distribution = Keyword.get(opts, :distribution, skill_distribution(source))
    run_kind = Keyword.get(opts, :run_kind, skill_run_kind(source))

    name =
      definition
      |> field("name", field(definition, "id", "skill"))
      |> to_string()
      |> slugify_name()

    slash =
      definition
      |> field("slash", name)
      |> normalize_slash()

    source_attribution =
      Keyword.get(opts, :source_attribution, %{
        source: source,
        source_id: source_id,
        distribution: distribution
      })

    mcp_tool = field(definition, "mcp_tool", nil)

    run_spec =
      Keyword.get_lazy(opts, :run_spec, fn ->
        %{
          kind: run_kind,
          skill_id: definition |> field("id", name) |> to_string()
        }
        |> maybe_put(:mcp_tool, mcp_tool)
      end)

    metadata =
      Keyword.get(opts, :metadata, %{})
      |> Map.merge(%{
        distribution: distribution,
        source_attribution: source_attribution
      })

    %{
      id: Keyword.get(opts, :id, "#{run_kind}:#{name}"),
      name: name,
      slash: slash,
      source: source,
      source_id: source_id,
      source_attribution: source_attribution,
      type: :slash_command,
      category: :skills,
      summary:
        definition |> field("description", field(definition, "summary", "")) |> to_string(),
      aliases: normalize_aliases(field(definition, "aliases", [])),
      args: normalize_args(field(definition, "args", [])),
      availability: Keyword.get(opts, :availability, :available),
      runnable?: Keyword.get(opts, :runnable?, true),
      run_spec: run_spec,
      metadata: metadata
    }
  end

  @doc false
  @spec normalize_slash(String.t()) :: String.t()
  def normalize_slash(command) when is_binary(command) do
    command = String.trim(command)

    if String.starts_with?(command, "/") do
      command
    else
      "/#{command}"
    end
  end

  @doc false
  @spec slugify_name(String.t()) :: String.t()
  def slugify_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  @doc false
  def normalize_args(args) do
    args
    |> List.wrap()
    |> Enum.map(&normalize_arg!/1)
  end

  defp normalize_arg!(arg) when is_map(arg) do
    %{
      name: arg |> field("name", "") |> to_string(),
      required?: arg |> field("required?", field(arg, "required", false)) |> truthy?(),
      description: arg |> field("description", "") |> to_string()
    }
  end

  defp normalize_arg!(name) when is_binary(name) do
    %{name: name, required?: false, description: ""}
  end

  defp normalize_aliases(aliases) do
    aliases
    |> List.wrap()
    |> Enum.map(&normalize_slash(to_string(&1)))
  end

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, atom_key(key), default))
  end

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key("aliases"), do: :aliases
  defp atom_key("args"), do: :args
  defp atom_key("category"), do: :category
  defp atom_key("description"), do: :description
  defp atom_key("id"), do: :id
  defp atom_key("mcp_tool"), do: :mcp_tool
  defp atom_key("name"), do: :name
  defp atom_key("required"), do: :required
  defp atom_key("required?"), do: :required?
  defp atom_key("run_spec"), do: :run_spec
  defp atom_key("slash"), do: :slash
  defp atom_key("source_id"), do: :source_id
  defp atom_key("summary"), do: :summary
  defp atom_key(_key), do: :__missing_registry_adapter_key__

  defp skill_distribution(:bundled_skill), do: :bundled
  defp skill_distribution(:local), do: :local
  defp skill_distribution(:dynamic_skill), do: :dynamic
  defp skill_distribution(source), do: source

  defp skill_run_kind(:bundled_skill), do: :bundled_skill
  defp skill_run_kind(:local), do: :local_skill
  defp skill_run_kind(:dynamic_skill), do: :dynamic_skill
  defp skill_run_kind(source), do: source

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
end
