defmodule Ourocode.Runtime.DynamicSkillDiscoveryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry
  alias Ourocode.Journal
  alias Ourocode.Runtime.DynamicSkillDiscovery

  test "discover adds dynamic skills to the supervised registry and journals an update" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-dynamic-skill-#{System.unique_integer([:positive])}.jsonl"
      )

    {:ok, registry} = Registry.load(skill_dirs: [], plugin_config: nil)
    command_registry_pid = start_supervised!({Agent, fn -> registry end})

    runtime = %{
      services: %{command_registry: command_registry_pid},
      journal: %{path: journal_path}
    }

    on_exit(fn ->
      File.rm(journal_path)
    end)

    skill = %{
      id: "session-skill-diagnose",
      name: "Session Diagnose",
      description: "Inspect the focused session.",
      aliases: ["/diagnose-session"],
      args: [],
      mcp_tool: "session_diagnose",
      source_id: "parent-session"
    }

    assert {:ok, result} =
             DynamicSkillDiscovery.discover(runtime, [skill],
               occurred_at_ms: 123,
               session_id: "session-1",
               discovered_from: "test-index"
             )

    assert [%{slash: "/session-diagnose"}] = result.accepted_entries
    assert result.event.payload.accepted_slashes == ["/session-diagnose"]
    assert result.event.payload.discovered_count == 1
    assert result.event.payload.discovered_from == "test-index"

    updated_registry = Agent.get(command_registry_pid, & &1)
    assert {:ok, entry} = Registry.fetch(updated_registry, "/diagnose-session")
    assert entry.slash == "/session-diagnose"

    assert {:ok, [journaled_event]} = Journal.read_ordered(journal_path)
    assert journaled_event.type == :command_registry_updated
    assert journaled_event.payload["accepted_slashes"] == ["/session-diagnose"]
  end

  test "discover reports unavailable command registry when runtime services are incomplete" do
    assert DynamicSkillDiscovery.discover(%{}, []) == {:error, :command_registry_unavailable}
  end
end
