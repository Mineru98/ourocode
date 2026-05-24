defmodule Ourocode.Command.CapabilityPreflight.Projection do
  @moduledoc """
  JSON-safe projections for command capability preflight.
  """

  @spec capability(map()) :: map()
  def capability(entry) do
    %{
      id: entry.id,
      name: entry.name,
      slash: entry.slash,
      aliases: entry.aliases,
      source: entry.source,
      source_id: entry.source_id,
      category: entry.category,
      summary: entry.summary,
      args: entry.args,
      run_spec: entry.run_spec,
      metadata: %{
        plugin_id: get_in(entry, [:metadata, :plugin_id]),
        plugin_source: get_in(entry, [:metadata, :plugin_source]),
        namespace_owner: get_in(entry, [:metadata, :namespace_owner]),
        command_namespace: get_in(entry, [:metadata, :command_namespace])
      }
    }
  end

  @spec side_effects(map()) :: map()
  def side_effects(entry) do
    %{
      execution: :none,
      discovery: :read_only,
      expected_outputs: expected_outputs(entry),
      risk_class: risk_class(entry)
    }
  end

  defp expected_outputs(entry) do
    entry
    |> get_in([:metadata, :expected_outputs])
    |> List.wrap()
  end

  defp risk_class(%{source: :plugin, metadata: metadata}) do
    metadata
    |> Map.get(:trust_evaluation, %{})
    |> metadata_value("trust_classification")
    |> case do
      nil -> :unknown
      value -> value
    end
  end

  defp risk_class(_entry), do: :not_applicable

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key, Map.get(metadata, String.to_atom(key)))
  end
end
