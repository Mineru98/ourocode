defmodule Ourocode.Terminal.CommandPaletteArea do
  @moduledoc """
  Terminal-safe renderer for the merged slash command and skill palette.

  The palette consumes the normalized command registry shape instead of
  rebuilding command lists locally, so builtin commands, skills, plugin
  commands, MCP tools, and dynamic entries share one display path.
  """

  alias Ourocode.Command.Registry

  alias Ourocode.Terminal.{
    CommandPaletteEntry,
    CommandPaletteSelection
  }

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
      entries: Enum.map(Registry.entries(registry), &CommandPaletteEntry.model/1)
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
        Enum.map(entries, &CommandPaletteEntry.line/1)
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
    |> Enum.map(&CommandPaletteEntry.model/1)
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
    CommandPaletteSelection.select(registry, selection)
  end

  defp format_sources([]), do: "none"
  defp format_sources(sources), do: Enum.map_join(sources, ",", &to_string/1)
end
