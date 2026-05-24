defmodule Ourocode.Command.Registry.MergeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.Merge

  test "run appends accepted entries and updates lookups, sources, and counts" do
    registry = registry([entry(:builtin, "/help")])
    skill = entry(:local, "/build", aliases: ["/b"], id: "local:/build", source_id: "skills")

    assert {:ok, merged} = Merge.run([skill], registry)

    assert merged.ordered == [entry(:builtin, "/help"), skill]
    assert merged.entries["/build"] == skill
    assert merged.aliases["/b"] == "/build"
    assert merged.sources == [:builtin, :local]
    assert merged.loaded_count == 2
    assert merged.duplicate_count == 0
  end

  test "run records slash collision against existing command" do
    builtin = entry(:builtin, "/help")
    duplicate = entry(:local, "/help", id: "local:/help")

    assert {:ok, merged} = Merge.run([duplicate], registry([builtin]))

    assert merged.ordered == [builtin]

    assert [
             %{
               reason: :slash_collision,
               source: :local,
               loser: ^duplicate,
               winner: ^builtin,
               token: "/help"
             }
           ] = merged.duplicates
  end

  test "run records alias collision against accepted entries from the same batch" do
    first = entry(:local, "/one", aliases: ["/shared"], id: "local:/one")
    second = entry(:local, "/two", aliases: ["/shared"], id: "local:/two")

    assert {:ok, merged} = Merge.run([second, first], registry([]))

    assert Enum.map(merged.ordered, & &1.slash) == ["/one"]

    assert [
             %{
               reason: :alias_collision,
               loser: ^second,
               winner: ^first,
               token: "/shared"
             }
           ] = merged.duplicates
  end

  test "run records id collision even when slash differs" do
    existing = entry(:builtin, "/help", id: "same-id")
    incoming = entry(:local, "/assist", id: "same-id")

    assert {:ok, merged} = Merge.run([incoming], registry([existing]))

    assert [
             %{
               reason: :id_collision,
               loser: ^incoming,
               winner: ^existing,
               token: "same-id"
             }
           ] = merged.duplicates
  end

  test "command_resolution_key prioritizes sources before slash" do
    sorted =
      [
        entry(:dynamic_skill, "/a"),
        entry(:builtin, "/z"),
        entry(:plugin, "/m"),
        entry(:local, "/b")
      ]
      |> Enum.sort_by(&Merge.command_resolution_key/1)

    assert Enum.map(sorted, & &1.source) == [:builtin, :local, :plugin, :dynamic_skill]
  end

  defp registry(entries) do
    %{
      status: :ready,
      sources: entries |> Enum.map(& &1.source) |> Enum.uniq(),
      entries: Map.new(entries, &{&1.slash, &1}),
      aliases:
        entries
        |> Enum.flat_map(fn entry -> Enum.map(entry.aliases, &{&1, entry.slash}) end)
        |> Map.new(),
      ordered: entries,
      loaded_count: length(entries),
      duplicates: [],
      duplicate_count: 0
    }
  end

  defp entry(source, slash, opts \\ []) do
    name = slash |> String.trim_leading("/") |> String.replace("/", "-")

    %{
      id: Keyword.get(opts, :id, "#{source}:#{slash}"),
      name: name,
      slash: slash,
      source: source,
      source_id: Keyword.get(opts, :source_id, to_string(source)),
      source_attribution: %{source: source},
      type: :slash_command,
      category: :test,
      summary: "summary",
      aliases: Keyword.get(opts, :aliases, []),
      args: [],
      availability: :available,
      runnable?: true,
      run_spec: %{},
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
