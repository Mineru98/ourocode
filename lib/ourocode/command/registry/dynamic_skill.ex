defmodule Ourocode.Command.Registry.DynamicSkill do
  @moduledoc """
  Normalizes session-discovered skills into command registry entries.
  """

  alias Ourocode.Command.RegistryEntryAdapter

  @spec normalize!(map()) :: map()
  def normalize!(definition) when is_map(definition) do
    name =
      definition
      |> field("name", field(definition, "id", "dynamic-skill"))
      |> to_string()
      |> slugify_name()

    source_id =
      definition
      |> field("source_id", field(definition, "session_id", "session"))
      |> to_string()

    discovered_from =
      definition
      |> field("discovered_from", "session")
      |> to_string()

    mcp_tool = field(definition, "mcp_tool", nil)
    input_schema = field(definition, "input_schema", %{})

    source_attribution = %{
      source: :dynamic_skill,
      source_id: source_id,
      distribution: :dynamic,
      discovered_from: discovered_from
    }

    RegistryEntryAdapter.from_skill_definition!(definition,
      id: "dynamic_skill:#{source_id}:#{name}",
      source: :dynamic_skill,
      source_id: source_id,
      source_attribution: source_attribution,
      distribution: :dynamic,
      run_kind: :dynamic_skill,
      run_spec:
        %{
          kind: :dynamic_skill,
          skill_id: field(definition, "id", name) |> to_string(),
          discovered_from: discovered_from
        }
        |> maybe_put(:mcp_tool, mcp_tool)
        |> maybe_put(:input_schema, input_schema),
      metadata: %{
        distribution: :dynamic,
        discovered_from: discovered_from,
        mcp_tool: mcp_tool,
        input_schema: input_schema,
        source_attribution: source_attribution
      }
    )
  end

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, atom_key(key), default))
  end

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key("discovered_from"), do: :discovered_from
  defp atom_key("id"), do: :id
  defp atom_key("input_schema"), do: :input_schema
  defp atom_key("inputSchema"), do: :inputSchema
  defp atom_key("mcp_tool"), do: :mcp_tool
  defp atom_key("name"), do: :name
  defp atom_key("session_id"), do: :session_id
  defp atom_key("source_id"), do: :source_id
  defp atom_key(_key), do: :__missing_dynamic_skill_key__

  defp slugify_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, _key, empty) when empty == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
