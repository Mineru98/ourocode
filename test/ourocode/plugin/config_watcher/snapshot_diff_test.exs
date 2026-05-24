defmodule Ourocode.Plugin.ConfigWatcher.SnapshotDiffTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigWatcher.SnapshotDiff

  test "detects created, modified, and deleted source snapshots" do
    missing = [snapshot(exists?: false)]
    created = [snapshot(exists?: true, size: 10, mtime: 1, checksum: "a")]
    modified = [snapshot(exists?: true, size: 10, mtime: 2, checksum: "b")]
    deleted = [snapshot(exists?: false)]

    assert SnapshotDiff.diff(missing, created) == [{:created, hd(created)}]
    assert SnapshotDiff.diff(created, modified) == [{:modified, hd(modified)}]
    assert SnapshotDiff.diff(modified, deleted) == [{:deleted, hd(deleted)}]
    assert SnapshotDiff.diff(deleted, deleted) == []
  end

  test "ignores unchanged existing snapshots" do
    before = [snapshot(exists?: true, size: 10, mtime: 1, checksum: "a")]
    after_snapshots = [snapshot(exists?: true, size: 10, mtime: 1, checksum: "a")]

    assert SnapshotDiff.diff(before, after_snapshots) == []
  end

  test "classifies relevance by source kind" do
    assert SnapshotDiff.relevance(:modified, snapshot(kind: :plugin_config)) ==
             :relevant_config_change

    assert SnapshotDiff.relevance(:modified, snapshot(kind: :plugin_settings)) ==
             :relevant_plugin_settings_change
  end

  defp snapshot(overrides) do
    %{
      path: "/tmp/ourocode/plugin.json",
      kind: :plugin_config,
      exists?: true,
      size: 1,
      mtime: 1,
      checksum: "checksum"
    }
    |> Map.merge(Map.new(overrides))
  end
end
