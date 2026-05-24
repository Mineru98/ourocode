defmodule Ourocode.Terminal.CommandPaletteDetail do
  @moduledoc """
  Detail rows for the interactive command palette overlay.
  """

  alias Ourocode.Runtime.CapabilityGraph
  alias Ourocode.Terminal.Screen

  @spec rows(map(), pos_integer()) :: [String.t()]
  def rows(entry, inner) when is_map(entry) and is_integer(inner) and inner > 0 do
    semantics =
      entry
      |> capability_registry()
      |> CapabilityGraph.build()
      |> Map.fetch!(:capabilities)
      |> List.first()
      |> Map.fetch!(:semantics)

    aliases =
      case Map.get(entry, :aliases, []) do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    args =
      entry
      |> Map.get(:args, [])
      |> Enum.map(fn arg ->
        suffix = if Map.get(arg, :required?), do: "!", else: "?"
        "#{Map.get(arg, :name, "arg")}#{suffix}"
      end)
      |> case do
        [] -> "none"
        values -> Enum.join(values, ", ")
      end

    [
      "selected #{entry.slash}  source=#{entry.source} trust=#{trust_tier(entry)} category=#{entry.category} availability=#{entry.availability}",
      "capability #{semantics.scope}/#{semantics.mutation_class}/#{semantics.approval_class}  aliases=#{aliases}  args=#{args}"
    ]
    |> Enum.map(&Screen.truncate(&1, inner))
  end

  @spec trust_tier(map()) :: String.t()
  def trust_tier(%{source: :builtin}), do: "builtin"
  def trust_tier(%{source: :bundled_skill}), do: "bundled"
  def trust_tier(%{source: :local}), do: "local"
  def trust_tier(%{source: :plugin}), do: "plugin"
  def trust_tier(%{source: :mcp}), do: "mcp"
  def trust_tier(%{source: :dynamic_skill}), do: "dynamic"
  def trust_tier(_entry), do: "unknown"

  @spec capability_registry(map()) :: map()
  def capability_registry(entry) when is_map(entry) do
    %{
      ordered: [
        %{
          id: "#{entry.source}:#{entry.slash}",
          name: entry.name,
          slash: entry.slash,
          summary: entry.summary,
          source: entry.source,
          source_id: to_string(entry.source),
          category: entry.category,
          run_spec: %{}
        }
      ]
    }
  end
end
