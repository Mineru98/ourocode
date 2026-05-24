defmodule Ourocode.Terminal.OooCommandsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.OooCommands

  test "fallback contains core ooo workflow commands" do
    commands = OooCommands.fallback()

    assert {"ooo interview", "clarify requirements through a Socratic interview"} in commands
    assert {"ooo run", "execute a Seed specification"} in commands
  end

  test "registry_entry? accepts core, plugin, dynamic skill, and ouroboros-prefixed entries" do
    assert OooCommands.registry_entry?(%{source: :builtin, name: "interview"})
    assert OooCommands.registry_entry?(%{source: :plugin, name: "superpowers"})
    assert OooCommands.registry_entry?(%{source: :dynamic_skill, name: "custom"})
    assert OooCommands.registry_entry?(%{source: :local, name: "ouroboros-custom"})

    refute OooCommands.registry_entry?(%{source: :builtin, name: "login"})
  end

  test "registry_command normalizes ouroboros prefixes into ooo commands" do
    assert OooCommands.registry_command(%{name: "ouroboros-status", summary: "status"}) ==
             {"ooo status", "status"}

    assert OooCommands.registry_command(%{name: "ouroboros_update", summary: "update"}) ==
             {"ooo update", "update"}
  end

  test "rank_by_usage preserves original order after usage count" do
    commands = [{"ooo run", "run"}, {"ooo seed", "seed"}, {"ooo help", "help"}]

    assert OooCommands.rank_by_usage(commands, %{"ooo seed" => 2}) == [
             {"ooo seed", "seed"},
             {"ooo run", "run"},
             {"ooo help", "help"}
           ]
  end
end
