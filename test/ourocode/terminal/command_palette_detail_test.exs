defmodule Ourocode.Terminal.CommandPaletteDetailTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.CommandPaletteDetail

  test "rows include user-facing command detail and safety copy" do
    entry = %{
      name: "Test",
      slash: "/test",
      summary: "Run test command",
      source: :plugin,
      category: :plugins,
      availability: :available,
      aliases: ["/t", "/try"],
      args: [%{name: "goal", required?: true}, %{name: "dry_run", required?: false}]
    }

    assert [
             "● /test · Plugin · Available",
             "Purpose · Run test command",
             "Safety · Workspace context · External changes · Asks first",
             "Usage · /t, /try · goal required · dry_run optional"
           ] = CommandPaletteDetail.rows(entry, 200)
  end

  test "rows use none for missing aliases and args and truncate to inner width" do
    entry = %{
      name: "Help",
      slash: "/help",
      summary: "Show help",
      source: :builtin,
      category: :discovery,
      availability: :stub,
      aliases: [],
      args: []
    }

    rows = CommandPaletteDetail.rows(entry, 96)

    assert length(rows) == 4
    assert Enum.all?(rows, &(String.length(&1) <= 96))
    assert Enum.join(rows, "\n") =~ "Built-in command"
    assert Enum.join(rows, "\n") =~ "No extra input"
    refute Enum.join(rows, "\n") =~ "source="
    refute Enum.join(rows, "\n") =~ "capability"
  end

  test "trust_tier maps known sources and falls back to unknown" do
    assert CommandPaletteDetail.trust_tier(%{source: :guided_work}) == "guided"
    assert CommandPaletteDetail.trust_tier(%{source: :bundled_skill}) == "bundled"
    assert CommandPaletteDetail.trust_tier(%{source: :local}) == "local"
    assert CommandPaletteDetail.trust_tier(%{source: :mcp}) == "mcp"
    assert CommandPaletteDetail.trust_tier(%{source: :dynamic_skill}) == "dynamic"
    assert CommandPaletteDetail.trust_tier(%{source: :unknown}) == "unknown"
  end

  test "capability_registry preserves command identity fields" do
    entry = %{
      name: "Seed",
      slash: "/seed",
      summary: "Generate a seed",
      source: :builtin,
      category: :workflow
    }

    assert %{ordered: [command]} = CommandPaletteDetail.capability_registry(entry)
    assert command.id == "builtin:/seed"
    assert command.name == "Seed"
    assert command.slash == "/seed"
    assert command.summary == "Generate a seed"
    assert command.source == :builtin
    assert command.source_id == "builtin"
    assert command.category == :workflow
  end
end
