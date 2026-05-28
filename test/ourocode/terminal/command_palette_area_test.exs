defmodule Ourocode.Terminal.CommandPaletteAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.{Registry, RegistryEntryAdapter}
  alias Ourocode.Terminal.CommandPaletteArea

  test "renders entries supplied by the merged command registry" do
    {:ok, registry} = Registry.load_builtin()

    skill =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "local-review",
          "name" => "Review Skill",
          "description" => "Run local review workflow.",
          "aliases" => ["/review-now"],
          "args" => [%{"name" => "target", "required" => true}]
        },
        id: "local_skill:review-skill",
        source: :local,
        source_id: "/tmp/ourocode-skills",
        distribution: :local,
        run_kind: :local_skill
      )

    plugin_command =
      RegistryEntryAdapter.from_slash_command!(
        %{
          "name" => "Vim Toggle",
          "slash" => "/vim-toggle",
          "summary" => "Toggle vim keybindings.",
          "aliases" => ["/vim"]
        },
        id: "plugin:vim-mode:vim-toggle",
        source: :plugin,
        source_id: "vim-mode",
        distribution: :third_party,
        category: :plugins,
        run_spec: %{kind: :plugin_command, plugin_id: "vim-mode", action: "toggle"}
      )

    assert {:ok, registry} = Registry.merge_normalized_entries(registry, [plugin_command, skill])

    palette = CommandPaletteArea.render(registry)
    text = CommandPaletteArea.render_text(palette)

    assert palette.loaded_count == registry.loaded_count
    assert Enum.map(palette.entries, & &1.slash) == Enum.map(registry.ordered, & &1.slash)
    assert text =~ "commands: #{registry.loaded_count} available"
    assert text =~ "| /help"
    refute text =~ "[builtin/discovery]"

    assert text =~
             "| /review-skill      skill Run local review workflow. <target>"

    assert text =~
             "| /vim-toggle        plugin Toggle vim keybindings."
  end

  test "projects compact event entries from registry entries" do
    {:ok, registry} = Registry.load_builtin()

    assert [%{slash: "/help", source: :builtin, category: :discovery} | _] =
             CommandPaletteArea.event_entries(registry)
  end

  test "selects a registry-backed command or skill entry by palette index and slash" do
    {:ok, registry} = Registry.load_builtin()

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

    assert {:ok, registry} = Registry.merge_normalized_entries(registry, skill)

    assert {:ok, help} = CommandPaletteArea.select(registry, 1)
    assert help.slash == "/help"
    assert help.run_spec == %{kind: :builtin_action, action: :show_help}

    assert {:ok, selected_skill} = CommandPaletteArea.select(registry, "/review-skill")
    assert selected_skill.slash == "/review-skill"
    assert selected_skill.source == :local
    assert selected_skill.run_spec.kind == :local_skill

    assert {:error, {:selection_out_of_range, 999}} = CommandPaletteArea.select(registry, 999)
    assert {:error, :invalid_selection} = CommandPaletteArea.select(registry, 0)
  end
end
