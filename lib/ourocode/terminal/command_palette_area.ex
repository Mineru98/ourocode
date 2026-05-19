defmodule Ourocode.Terminal.CommandPaletteArea do
  @moduledoc """
  Terminal-safe renderer for the merged slash command and skill palette.

  The palette consumes the normalized command registry shape instead of
  rebuilding command lists locally, so builtin commands, skills, plugin
  commands, MCP tools, and dynamic entries share one display path.
  """

  alias Ourocode.Command.Registry

  @type t :: %{
          required(:id) => :command_palette,
          required(:region) => :command_palette,
          required(:status) => atom(),
          required(:loaded_count) => non_neg_integer(),
          required(:sources) => [atom()],
          required(:entries) => [map()]
        }

  @doc """
  Projects a command registry into a terminal render model.
  """
  @spec render(map()) :: t()
  def render(%{status: status, loaded_count: loaded_count, sources: sources} = registry) do
    %{
      id: :command_palette,
      region: :command_palette,
      title: "Command Palette",
      status: status,
      loaded_count: loaded_count,
      sources: sources,
      entries: Enum.map(Registry.entries(registry), &entry_model/1)
    }
  end

  @doc """
  Renders a command palette model as stable terminal text.
  """
  @spec render_text(t()) :: String.t()
  def render_text(%{entries: entries} = palette) do
    header =
      "+-- Command Palette (#{palette.loaded_count}) region=command_palette status=#{palette.status}"

    source_line = "| sources=#{format_sources(palette.sources)}"

    entry_lines =
      if entries == [] do
        ["| no commands or skills loaded"]
      else
        Enum.map(entries, &entry_line/1)
      end

    ([header, source_line] ++ entry_lines)
    |> Enum.join("\n")
  end

  @doc """
  Returns the compact event payload used when a palette is opened.
  """
  @spec event_entries(map()) :: [map()]
  def event_entries(registry) when is_map(registry) do
    registry
    |> Registry.entries()
    |> Enum.map(&entry_model/1)
  end

  @doc """
  Resolves one palette selection against the merged registry.

  Terminal selection is intentionally registry-backed instead of display-text
  backed, so callers receive the same normalized command/skill entry that slash
  dispatch and discovery use. Integer selections are one-based and follow the
  current display order; slash/name selections are useful for tests and future
  richer TUI frontends.
  """
  @spec select(map(), integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def select(registry, selection) when is_map(registry) do
    with {:ok, normalized_selection} <- normalize_selection(selection) do
      resolve_selection(registry, normalized_selection)
    end
  end

  defp normalize_selection(selection) when is_integer(selection) and selection > 0,
    do: {:ok, {:index, selection}}

  defp normalize_selection(selection) when is_binary(selection) do
    trimmed = String.trim(selection)

    cond do
      trimmed == "" ->
        {:error, :selection_required}

      match?({_, ""}, Integer.parse(trimmed)) ->
        {index, ""} = Integer.parse(trimmed)
        normalize_selection(index)

      String.starts_with?(trimmed, "/") ->
        {:ok, {:slash, trimmed}}

      true ->
        {:ok, {:name, trimmed}}
    end
  end

  defp normalize_selection(_selection), do: {:error, :invalid_selection}

  defp resolve_selection(registry, {:index, index}) do
    case registry |> Registry.entries() |> Enum.at(index - 1) do
      nil -> {:error, {:selection_out_of_range, index}}
      entry -> {:ok, entry}
    end
  end

  defp resolve_selection(registry, {:slash, slash}) do
    case Registry.fetch(registry, slash) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_selection, slash}}
    end
  end

  defp resolve_selection(registry, {:name, name}) do
    normalized_name = normalize_name(name)

    registry
    |> Registry.entries()
    |> Enum.find(&(normalize_name(Map.get(&1, :name, "")) == normalized_name))
    |> case do
      nil -> {:error, {:unknown_selection, name}}
      entry -> {:ok, entry}
    end
  end

  defp entry_model(entry) do
    %{
      id: Map.fetch!(entry, :id),
      slash: Map.fetch!(entry, :slash),
      name: Map.fetch!(entry, :name),
      summary: Map.get(entry, :summary, ""),
      source: Map.fetch!(entry, :source),
      source_id: Map.fetch!(entry, :source_id),
      category: Map.fetch!(entry, :category),
      aliases: Map.get(entry, :aliases, []),
      args: Map.get(entry, :args, []),
      availability: Map.get(entry, :availability, :available),
      runnable?: Map.get(entry, :runnable?, true)
    }
  end

  defp entry_line(entry) do
    parts = [
      "| #{entry.slash}",
      "[#{entry.source}/#{entry.category}]",
      availability_label(entry),
      args_label(entry),
      aliases_label(entry),
      summary_label(entry)
    ]

    parts
    |> Enum.reject(&(&1 in ["", nil]))
    |> Enum.join(" ")
  end

  defp availability_label(%{availability: :available, runnable?: true}), do: ""

  defp availability_label(%{availability: availability, runnable?: runnable?}) do
    "availability=#{availability} runnable?=#{runnable?}"
  end

  defp args_label(%{args: []}), do: ""

  defp args_label(%{args: args}) do
    rendered =
      args
      |> Enum.map(fn arg ->
        suffix = if Map.get(arg, :required?, false), do: "*", else: ""
        "#{Map.get(arg, :name, "arg")}#{suffix}"
      end)
      |> Enum.join(",")

    "args=#{rendered}"
  end

  defp aliases_label(%{aliases: []}), do: ""
  defp aliases_label(%{aliases: aliases}), do: "aliases=#{Enum.join(aliases, ",")}"

  defp summary_label(%{summary: ""}), do: ""
  defp summary_label(%{summary: summary}), do: ~s(summary="#{summary}")

  defp format_sources([]), do: "none"
  defp format_sources(sources), do: Enum.map_join(sources, ",", &to_string/1)

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s_]+/, "-")
  end
end
