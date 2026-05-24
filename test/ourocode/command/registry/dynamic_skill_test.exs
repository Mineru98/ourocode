defmodule Ourocode.Command.Registry.DynamicSkillTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.DynamicSkill

  test "normalizes discovered skill metadata into a dynamic registry entry" do
    entry =
      DynamicSkill.normalize!(%{
        "id" => "skill-42",
        "name" => "Live Refactor",
        "slash" => "live-refactor",
        "description" => "Apply a discovered refactor.",
        "source_id" => "child-session-1",
        "discovered_from" => "skill-index",
        "mcp_tool" => "live_refactor"
      })

    assert entry.id == "dynamic_skill:child-session-1:live-refactor"
    assert entry.name == "live-refactor"
    assert entry.slash == "/live-refactor"
    assert entry.source == :dynamic_skill
    assert entry.source_id == "child-session-1"

    assert entry.run_spec == %{
             kind: :dynamic_skill,
             skill_id: "skill-42",
             discovered_from: "skill-index",
             mcp_tool: "live_refactor"
           }

    assert entry.source_attribution == %{
             source: :dynamic_skill,
             source_id: "child-session-1",
             distribution: :dynamic,
             discovered_from: "skill-index"
           }

    assert entry.metadata.source_attribution == entry.source_attribution
  end

  test "accepts atom keyed metadata and omits blank mcp tool values" do
    entry =
      DynamicSkill.normalize!(%{
        id: "skill-atom",
        name: "Atom Skill",
        source_id: "session-atom",
        discovered_from: "runtime",
        mcp_tool: ""
      })

    assert entry.id == "dynamic_skill:session-atom:atom-skill"

    assert entry.run_spec == %{
             kind: :dynamic_skill,
             skill_id: "skill-atom",
             discovered_from: "runtime"
           }
  end
end
