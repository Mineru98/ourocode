defmodule Ourocode.Runtime.CapabilityGraph do
  @moduledoc """
  Deterministic capability projection for the currently loaded command surface.

  This stays local to ourocode's registry boundary: builtin commands, plugins,
  MCP entries, and dynamic skills are normalized into a small semantic view the
  terminal can show without calling a runtime.
  """

  alias Ourocode.Command.Registry

  @type mutation_class ::
          :read_only | :workspace_write | :external_side_effect | :destructive
  @type parallel_safety :: :safe | :serialized | :isolated_session_required
  @type approval_class :: :default | :elevated | :bypass_forbidden
  @type origin :: :builtin | :attached_mcp | :plugin | :skill | :future_runtime
  @type scope :: :kernel | :sidecar | :attachment | :shell_only

  @type capability :: %{
          required(:stable_id) => String.t(),
          required(:name) => String.t(),
          required(:command) => String.t(),
          required(:description) => String.t(),
          required(:source_kind) => atom(),
          required(:source_name) => String.t(),
          required(:category) => atom(),
          required(:semantics) => %{
            required(:mutation_class) => mutation_class(),
            required(:parallel_safety) => parallel_safety(),
            required(:approval_class) => approval_class(),
            required(:origin) => origin(),
            required(:scope) => scope()
          }
        }

  @type t :: %{
          required(:capabilities) => [capability()],
          required(:summary) => map()
        }

  @doc "Builds a capability graph from a normalized command registry."
  @spec build(Registry.t()) :: t()
  def build(%{ordered: ordered}) when is_list(ordered) do
    capabilities = Enum.map(ordered, &descriptor/1)

    %{
      capabilities: capabilities,
      summary: %{
        count: length(capabilities),
        sources: count_by(capabilities, :source_kind),
        categories: count_by(capabilities, :category),
        mutation_classes: count_by_semantic(capabilities, :mutation_class),
        origins: count_by_semantic(capabilities, :origin)
      }
    }
  end

  @doc "Renders the graph as compact terminal text."
  @spec render_text(t()) :: String.t()
  def render_text(%{capabilities: capabilities, summary: summary}) do
    sources =
      summary
      |> Map.get(:sources, %{})
      |> Enum.map(fn {source, count} -> "#{source}=#{count}" end)
      |> Enum.join(", ")

    header = "capabilities: #{summary.count} commands  #{sources}"

    rows =
      capabilities
      |> Enum.group_by(fn cap ->
        sem = cap.semantics
        {cap.source_kind, sem.scope, sem.mutation_class, sem.approval_class}
      end)
      |> Enum.sort_by(fn {{source, scope, mutation, approval}, _caps} ->
        {to_string(source), to_string(scope), to_string(mutation), to_string(approval)}
      end)
      |> Enum.flat_map(fn {{source, scope, mutation, approval}, caps} ->
        commands =
          caps
          |> Enum.map(& &1.command)
          |> Enum.join(", ")

        ["  #{source}/#{scope}/#{mutation}/#{approval}: #{commands}"]
      end)

    Enum.join([header | rows], "\n")
  end

  defp descriptor(entry) do
    %{
      stable_id: Map.get(entry, :id, Map.get(entry, :slash)),
      name: Map.get(entry, :name, Map.get(entry, :slash, "")),
      command: Map.get(entry, :slash, ""),
      description: Map.get(entry, :summary, ""),
      source_kind: Map.get(entry, :source, :unknown),
      source_name: Map.get(entry, :source_id, to_string(Map.get(entry, :source, :unknown))),
      category: Map.get(entry, :category, :commands),
      semantics: semantics(entry)
    }
  end

  defp semantics(entry) do
    mutation = mutation_class(entry)

    %{
      mutation_class: mutation,
      parallel_safety: parallel_safety(mutation, entry),
      approval_class: approval_class(mutation, entry),
      origin: origin(Map.get(entry, :source)),
      scope: scope(entry)
    }
  end

  defp mutation_class(entry) do
    fingerprint =
      [
        Map.get(entry, :name, ""),
        Map.get(entry, :slash, ""),
        Map.get(entry, :summary, ""),
        inspect(Map.get(entry, :run_spec, %{}))
      ]
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      has_word?(fingerprint, ["delete", "destroy", "drop", "kill"]) ->
        :destructive

      has_word?(fingerprint, ["cancel", "interrupt", "exit", "logout", "clear"]) ->
        :external_side_effect

      has_word?(fingerprint, ["write", "edit", "patch", "workspace"]) ->
        :workspace_write

      Map.get(entry, :category) in [:discovery, :visibility] ->
        :read_only

      Map.get(entry, :source) in [:plugin, :mcp, :dynamic_skill] ->
        :external_side_effect

      true ->
        :read_only
    end
  end

  defp parallel_safety(:read_only, _entry), do: :safe
  defp parallel_safety(:workspace_write, _entry), do: :serialized
  defp parallel_safety(:destructive, _entry), do: :isolated_session_required
  defp parallel_safety(:external_side_effect, _entry), do: :serialized

  defp approval_class(:destructive, _entry), do: :bypass_forbidden

  defp approval_class(:external_side_effect, %{source: source}) when source in [:plugin, :mcp],
    do: :elevated

  defp approval_class(:external_side_effect, _entry), do: :default
  defp approval_class(_mutation, _entry), do: :default

  defp origin(:builtin), do: :builtin
  defp origin(:mcp), do: :attached_mcp
  defp origin(:plugin), do: :plugin
  defp origin(source) when source in [:local, :bundled_skill, :dynamic_skill], do: :skill
  defp origin(_source), do: :future_runtime

  defp scope(%{source: :mcp}), do: :attachment
  defp scope(%{source: :plugin}), do: :attachment
  defp scope(%{category: category}) when category in [:plugins, :skills], do: :sidecar
  defp scope(%{category: :runtime}), do: :shell_only
  defp scope(_entry), do: :kernel

  defp has_word?(text, words) do
    Enum.any?(words, &Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(&1)}([^a-z0-9_]|$)/, text))
  end

  defp count_by(capabilities, key) do
    capabilities
    |> Enum.frequencies_by(&Map.fetch!(&1, key))
    |> Map.new()
  end

  defp count_by_semantic(capabilities, key) do
    capabilities
    |> Enum.frequencies_by(&Map.fetch!(&1.semantics, key))
    |> Map.new()
  end
end
