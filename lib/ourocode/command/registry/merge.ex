defmodule Ourocode.Command.Registry.Merge do
  @moduledoc """
  Pure merge and duplicate-resolution logic for command registry entries.
  """

  @spec run([map()], map()) :: {:ok, map()}
  def run(new_entries, registry) when is_list(new_entries) and is_map(registry) do
    {accepted_entries, duplicate_records} =
      new_entries
      |> Enum.sort_by(&command_resolution_key/1)
      |> Enum.reduce({[], []}, fn entry, {accepted, duplicates} ->
        lookup = command_lookup(registry, accepted)

        case duplicate_record(entry, lookup) do
          nil ->
            {accepted ++ [entry], duplicates}

          duplicate ->
            {accepted, duplicates ++ [duplicate]}
        end
      end)

    ordered = registry.ordered ++ accepted_entries

    entries =
      Map.merge(registry.entries, Map.new(accepted_entries, fn entry -> {entry.slash, entry} end))

    aliases =
      accepted_entries
      |> Enum.flat_map(fn entry -> Enum.map(entry.aliases, &{&1, entry.slash}) end)
      |> Map.new()
      |> then(&Map.merge(registry.aliases, &1))

    sources = Enum.uniq(registry.sources ++ Enum.map(accepted_entries, & &1.source))

    {:ok,
     %{
       registry
       | sources: sources,
         entries: entries,
         aliases: aliases,
         ordered: ordered,
         loaded_count: length(ordered),
         duplicates: Map.get(registry, :duplicates, []) ++ duplicate_records,
         duplicate_count: Map.get(registry, :duplicate_count, 0) + length(duplicate_records)
     }}
  end

  @spec command_resolution_key(map()) :: tuple()
  def command_resolution_key(entry) do
    {
      source_priority(entry.source),
      entry.slash,
      entry.source_id,
      get_in(entry, [:metadata, :skill_path]) || "",
      entry.id
    }
  end

  @spec source_priority(atom()) :: non_neg_integer()
  def source_priority(:builtin), do: 0
  def source_priority(:bundled_skill), do: 1
  def source_priority(:local), do: 2
  def source_priority(:plugin), do: 3
  def source_priority(:mcp), do: 4
  def source_priority(:dynamic_skill), do: 5

  @spec duplicate_record(map(), map()) :: map() | nil
  def duplicate_record(entry, lookup) do
    cond do
      winner = Map.get(lookup.entries, entry.slash) ->
        duplicate_record(:slash_collision, entry.source, entry, winner, entry.slash)

      winner_slash = Map.get(lookup.aliases, entry.slash) ->
        duplicate_record(
          :slash_collision,
          entry.source,
          entry,
          Map.fetch!(lookup.entries, winner_slash),
          entry.slash
        )

      conflict = alias_conflict(entry.aliases, lookup) ->
        {token, winner} = conflict
        duplicate_record(:alias_collision, entry.source, entry, winner, token)

      winner = Map.get(lookup.ids, entry.id) ->
        duplicate_record(:id_collision, entry.source, entry, winner, entry.id)

      true ->
        nil
    end
  end

  @spec command_lookup(map(), [map()]) :: map()
  def command_lookup(registry, accepted_entries) do
    accepted_entry_map = Map.new(accepted_entries, fn entry -> {entry.slash, entry} end)
    accepted_id_map = Map.new(accepted_entries, fn entry -> {entry.id, entry} end)

    accepted_alias_map =
      accepted_entries
      |> Enum.flat_map(fn entry -> Enum.map(entry.aliases, &{&1, entry.slash}) end)
      |> Map.new()

    %{
      entries: Map.merge(registry.entries, accepted_entry_map),
      aliases: Map.merge(registry.aliases, accepted_alias_map),
      ids: Map.merge(command_id_lookup(registry), accepted_id_map)
    }
  end

  defp command_id_lookup(registry) do
    registry.ordered
    |> Map.new(fn entry -> {entry.id, entry} end)
  end

  defp duplicate_record(reason, source, loser, winner, token) do
    %{
      reason: reason,
      source: source,
      loser: loser,
      winner: winner,
      token: token
    }
  end

  defp alias_conflict(aliases, lookup) do
    Enum.find_value(aliases, fn alias ->
      cond do
        winner = Map.get(lookup.entries, alias) ->
          {alias, winner}

        winner_slash = Map.get(lookup.aliases, alias) ->
          {alias, Map.fetch!(lookup.entries, winner_slash)}

        true ->
          nil
      end
    end)
  end
end
