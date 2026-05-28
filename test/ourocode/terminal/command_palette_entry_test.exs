defmodule Ourocode.Terminal.CommandPaletteEntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.CommandPaletteEntry

  test "projects normalized registry entries into compact palette models" do
    entry = %{
      id: "local_skill:review-skill",
      slash: "/review-skill",
      name: "Review Skill",
      summary: "Run local review workflow.",
      source: :local,
      source_id: "/tmp/ourocode-skills",
      category: :skills,
      aliases: ["/review-now"],
      args: [%{name: "target", required?: true}],
      availability: :available,
      runnable?: true,
      ignored: :field
    }

    assert CommandPaletteEntry.model(entry) == %{
             id: "local_skill:review-skill",
             slash: "/review-skill",
             name: "Review Skill",
             summary: "Run local review workflow.",
             source: :local,
             source_id: "/tmp/ourocode-skills",
             category: :skills,
             aliases: ["/review-now"],
             args: [%{name: "target", required?: true}],
             availability: :available,
             runnable?: true
           }
  end

  test "formats product-facing terminal lines with arguments" do
    entry = %{
      slash: "/review-skill",
      source: :local,
      category: :skills,
      aliases: ["/review-now"],
      args: [%{name: "target", required?: true}, %{name: "mode"}],
      availability: :blocked,
      runnable?: false,
      summary: "Run local review workflow."
    }

    assert CommandPaletteEntry.line(entry) ==
             "| /review-skill      skill Run local review workflow. <target> [mode]"
  end
end
