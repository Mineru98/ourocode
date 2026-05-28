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

    [
      "● #{entry.slash} · #{source_label(entry)} · #{availability_label(entry)}",
      "Purpose · #{summary(entry)}",
      "Safety · #{scope_label(semantics.scope)} · #{mutation_label(semantics.mutation_class)} · #{approval_label(semantics.approval_class)}",
      usage_label(entry)
    ]
    |> Enum.map(&Screen.truncate(&1, inner))
  end

  @spec trust_tier(map()) :: String.t()
  def trust_tier(%{source: :builtin}), do: "builtin"
  def trust_tier(%{source: :guided_work}), do: "guided"
  def trust_tier(%{source: :bundled_skill}), do: "bundled"
  def trust_tier(%{source: :local}), do: "local"
  def trust_tier(%{source: :plugin}), do: "plugin"
  def trust_tier(%{source: :mcp}), do: "mcp"
  def trust_tier(%{source: :dynamic_skill}), do: "dynamic"
  def trust_tier(_entry), do: "unknown"

  defp source_label(%{source: :builtin}), do: "Built-in command"
  defp source_label(%{source: :guided_work}), do: "Guided work"
  defp source_label(%{source: :bundled_skill}), do: "Included skill"
  defp source_label(%{source: :local}), do: "Local skill"
  defp source_label(%{source: :plugin}), do: "Plugin"
  defp source_label(%{source: :mcp}), do: "Connected tool"
  defp source_label(%{source: :dynamic_skill}), do: "Dynamic skill"
  defp source_label(_entry), do: "Command"

  defp availability_label(%{availability: :available}), do: "Available"
  defp availability_label(%{availability: :ready}), do: "Ready"
  defp availability_label(%{availability: :stub}), do: "Preview only"
  defp availability_label(%{availability: :unavailable}), do: "Unavailable"

  defp availability_label(%{availability: availability}) when is_atom(availability) do
    availability
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp availability_label(_entry), do: "Available"

  defp summary(%{summary: summary}) when is_binary(summary) and summary != "", do: summary
  defp summary(%{name: name}) when is_binary(name) and name != "", do: name
  defp summary(_entry), do: "Run this command"

  defp usage_label(entry) do
    [aliases_label(Map.get(entry, :aliases, [])), args_label(Map.get(entry, :args, []))]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> "Usage · No extra input"
      parts -> "Usage · " <> Enum.join(parts, " · ")
    end
  end

  defp aliases_label([]), do: ""
  defp aliases_label(values), do: Enum.join(values, ", ")

  defp args_label([]), do: "No extra input"

  defp args_label(args) do
    rendered =
      Enum.map(args, fn arg ->
        name = Map.get(arg, :name, "arg")
        if Map.get(arg, :required?), do: "#{name} required", else: "#{name} optional"
      end)

    Enum.join(rendered, " · ")
  end

  defp scope_label(:kernel), do: "Runs inside ourocode"
  defp scope_label(:attachment), do: "Workspace context"
  defp scope_label(:workspace), do: "This workspace"
  defp scope_label(_scope), do: "Scoped"

  defp mutation_label(:read_only), do: "Read-only"
  defp mutation_label(:local_side_effect), do: "Local changes"
  defp mutation_label(:external_side_effect), do: "External changes"
  defp mutation_label(_mutation), do: "Checked before run"

  defp approval_label(:default), do: "No extra approval"
  defp approval_label(:elevated), do: "Asks first"
  defp approval_label(:interactive), do: "May ask follow-up"
  defp approval_label(_approval), do: "Approval handled here"

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
