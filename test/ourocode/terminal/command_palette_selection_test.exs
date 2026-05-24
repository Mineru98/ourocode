defmodule Ourocode.Terminal.CommandPaletteSelectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.{Registry, RegistryEntryAdapter}
  alias Ourocode.Terminal.CommandPaletteSelection

  test "selects registry entries by one-based index, numeric text, slash, or normalized name" do
    {:ok, registry} = registry_with_skill()

    assert {:ok, help} = CommandPaletteSelection.select(registry, 1)
    assert help.slash == "/help"

    assert {:ok, same_help} = CommandPaletteSelection.select(registry, "1")
    assert same_help.slash == "/help"

    assert {:ok, selected_skill} = CommandPaletteSelection.select(registry, "/review-skill")
    assert selected_skill.source == :local

    assert {:ok, named_skill} = CommandPaletteSelection.select(registry, "review_skill")
    assert named_skill.slash == "/review-skill"
  end

  test "returns stable errors for invalid, missing, or out-of-range selections" do
    {:ok, registry} = Registry.load_builtin()

    assert CommandPaletteSelection.select(registry, 0) == {:error, :invalid_selection}
    assert CommandPaletteSelection.select(registry, " ") == {:error, :selection_required}

    assert CommandPaletteSelection.select(registry, 999) ==
             {:error, {:selection_out_of_range, 999}}

    assert CommandPaletteSelection.select(registry, "/missing") ==
             {:error, {:unknown_selection, "/missing"}}

    assert CommandPaletteSelection.select(registry, "missing") ==
             {:error, {:unknown_selection, "missing"}}
  end

  defp registry_with_skill do
    skill =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "local-review",
          "name" => "Review Skill",
          "description" => "Run local review workflow."
        },
        id: "local_skill:review-skill",
        source: :local,
        source_id: "/tmp/ourocode-skills",
        distribution: :local,
        run_kind: :local_skill
      )

    with {:ok, registry} <- Registry.load_builtin() do
      Registry.merge_normalized_entries(registry, skill)
    end
  end
end
