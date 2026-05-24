defmodule Ourocode.Plugin.ConfigWatcher.PollTest do
  use ExUnit.Case, async: false

  alias Ourocode.Journal
  alias Ourocode.Plugin.ConfigWatcher.Poll
  alias Ourocode.Plugin.ConfigWatcher.Sources

  test "run emits journaled reload events and updates watcher state" do
    project_dir = tmp_dir!("config-watcher-poll")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    journal_path = Path.join(project_dir, ".ourocode/journals/poll.jsonl")
    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(journal_path))

    watch_sources = [
      %{kind: :plugin_config, path: Path.expand(config_path)}
    ]

    state = %{
      project_dir: project_dir,
      watch_sources: watch_sources,
      snapshots: Sources.snapshots(watch_sources),
      subscribers: [self(), :ignored],
      journal_path: journal_path,
      watcher_id: "poll-test",
      emitted_count: 0,
      last_reload_requests: []
    }

    File.write!(config_path, "{}")

    assert {[event], next_state} = Poll.run(state)

    assert event.type == :plugin_config_reload_requested
    assert event.change == :created
    assert event.config_source_path == Path.expand(config_path)
    assert next_state.emitted_count == 1
    assert next_state.last_reload_requests == [event]
    assert [%{exists?: true}] = next_state.snapshots

    assert_receive {:plugin_config_reload_requested, ^event}

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :plugin_config_reload_requested
    assert journaled.change == :created
  end

  test "run updates snapshots without emitting unchanged sources" do
    project_dir = tmp_dir!("config-watcher-poll-unchanged")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, "{}")

    watch_sources = [
      %{kind: :plugin_config, path: Path.expand(config_path)}
    ]

    snapshots = Sources.snapshots(watch_sources)

    state = %{
      project_dir: project_dir,
      watch_sources: watch_sources,
      snapshots: snapshots,
      subscribers: [self()],
      journal_path: nil,
      watcher_id: "poll-unchanged-test",
      emitted_count: 2,
      last_reload_requests: [:old]
    }

    assert {[], next_state} = Poll.run(state)
    assert next_state.emitted_count == 2
    assert next_state.last_reload_requests == []
    refute_receive {:plugin_config_reload_requested, _event}, 20
  end

  defp tmp_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
