defmodule Ourocode.Terminal.Palette do
  @moduledoc """
  Pure command/skill palette model for the `/` overlay.

  Backed by the merged builtin command registry (the seed's single command
  surface), this filters and selects entries for the terminal palette. It owns
  no IO or process state so the overlay logic is unit-testable; the TUI only
  draws what this returns and routes the chosen slash through the existing
  command execution path.
  """

  alias Ourocode.Command.Registry
  alias Ourocode.Terminal.Fuzzy

  @type entry :: %{
          slash: String.t(),
          name: String.t(),
          summary: String.t(),
          category: atom(),
          source: atom(),
          availability: atom(),
          aliases: [String.t()],
          args: [map()]
        }

  @doc "All palette entries in registry display order."
  @spec entries() :: [entry()]
  def entries do
    {:ok, registry} = Registry.load_builtin()

    registry
    |> Registry.entries()
    |> Enum.map(fn e ->
      %{
        slash: e.slash,
        name: e.name,
        summary: e.summary,
        category: e.category,
        source: e.source,
        availability: e.availability,
        aliases: e.aliases,
        args: e.args
      }
    end)
  end

  @doc """
  Filters entries by a `/`-prefixed query.

  An empty or bare `/` query returns everything. Matching is fuzzy against the
  slash, name, aliases, and summary while preserving registry order as a
  tie-breaker.
  """
  @spec filter([entry()], String.t()) :: [entry()]
  def filter(entries, query) do
    slash_query? = query |> String.trim() |> String.starts_with?("/")

    needle =
      query
      |> String.trim()
      |> String.trim_leading("/")
      |> String.downcase()

    if needle == "" do
      entries
    else
      entries
      |> Enum.map(fn e -> {palette_search_text(e, slash_query?), e} end)
      |> Fuzzy.rank(needle)
    end
  end

  defp palette_search_text(entry, true) do
    [
      entry.slash,
      entry.name,
      Map.get(entry, :aliases, [])
    ]
    |> List.flatten()
    |> Enum.join(" ")
  end

  defp palette_search_text(entry, false) do
    [
      entry.slash,
      entry.name,
      entry.summary,
      Map.get(entry, :aliases, [])
    ]
    |> List.flatten()
    |> Enum.join(" ")
  end

  @doc "Clamps a selection index into `[0, count)` (0 when empty)."
  @spec clamp(integer(), non_neg_integer()) :: non_neg_integer()
  def clamp(_index, 0), do: 0
  def clamp(index, count), do: Integer.mod(index, count)

  @doc "Returns the entry at `index` in `entries`, or nil."
  @spec selected([entry()], integer()) :: entry() | nil
  def selected([], _index), do: nil

  def selected(entries, index) do
    Enum.at(entries, clamp(index, length(entries)))
  end
end
