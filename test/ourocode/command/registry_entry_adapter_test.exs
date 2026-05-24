defmodule Ourocode.Command.RegistryEntryAdapterTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.RegistryEntryAdapter

  test "slash command adapter normalizes definitions into the shared registry entry shape" do
    entry =
      RegistryEntryAdapter.from_slash_command!(
        %{
          name: "Pane Focus",
          slash: "pane",
          aliases: ["focus", "/select-pane"],
          category: :steering,
          summary: "Focus a pane.",
          args: [%{name: "pane_id", required?: true, description: "Pane id"}],
          run_spec: %{kind: :builtin_action, action: :focus_pane}
        },
        source: :builtin,
        source_id: "builtin",
        distribution: :builtin,
        id: "builtin:/pane",
        metadata: %{introduced_in: :interactive_baseline}
      )

    assert entry.id == "builtin:/pane"
    assert entry.name == "pane-focus"
    assert entry.slash == "/pane"
    assert entry.source == :builtin
    assert entry.source_id == "builtin"

    assert entry.source_attribution == %{
             source: :builtin,
             source_id: "builtin",
             distribution: :builtin
           }

    assert entry.type == :slash_command
    assert entry.category == :steering
    assert entry.summary == "Focus a pane."
    assert entry.aliases == ["/focus", "/select-pane"]
    assert entry.args == [%{name: "pane_id", required?: true, description: "Pane id"}]
    assert entry.availability == :available
    assert entry.runnable? == true
    assert entry.run_spec == %{kind: :builtin_action, action: :focus_pane}
    assert entry.metadata.introduced_in == :interactive_baseline
    assert entry.metadata.source_attribution == entry.source_attribution
  end

  test "skill adapter normalizes skill definitions into the same registry entry shape" do
    source_attribution = %{
      source: :dynamic_skill,
      source_id: "child-session-1",
      distribution: :dynamic,
      discovered_from: "skill-index"
    }

    entry =
      RegistryEntryAdapter.from_skill_definition!(
        %{
          "id" => "skill-123",
          "name" => "Live Refactor",
          "slash" => "live-refactor",
          "description" => "Apply a discovered refactor.",
          "aliases" => ["refactor-now"],
          "args" => [%{"name" => "target", "required" => true, "description" => "Target file"}],
          "mcp_tool" => "live_refactor"
        },
        id: "dynamic_skill:child-session-1:live-refactor",
        source: :dynamic_skill,
        source_id: "child-session-1",
        distribution: :dynamic,
        run_kind: :dynamic_skill,
        source_attribution: source_attribution,
        run_spec: %{
          kind: :dynamic_skill,
          skill_id: "skill-123",
          discovered_from: "skill-index",
          mcp_tool: "live_refactor"
        },
        metadata: %{discovered_from: "skill-index"}
      )

    assert entry.id == "dynamic_skill:child-session-1:live-refactor"
    assert entry.name == "live-refactor"
    assert entry.slash == "/live-refactor"
    assert entry.source == :dynamic_skill
    assert entry.source_id == "child-session-1"
    assert entry.source_attribution == source_attribution
    assert entry.type == :slash_command
    assert entry.category == :skills
    assert entry.summary == "Apply a discovered refactor."
    assert entry.aliases == ["/refactor-now"]
    assert entry.args == [%{name: "target", required?: true, description: "Target file"}]
    assert entry.availability == :available
    assert entry.runnable? == true
    assert entry.run_spec.kind == :dynamic_skill
    assert entry.run_spec.mcp_tool == "live_refactor"
    assert entry.metadata.distribution == :dynamic
    assert entry.metadata.discovered_from == "skill-index"
    assert entry.metadata.source_attribution == entry.source_attribution
  end
end
