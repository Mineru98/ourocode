defmodule Ourocode.Plugin.ConfigWatcher.SourcesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigWatcher.Sources

  test "config_paths prefers explicit source paths and normalizes order" do
    project_dir = tmp_dir("sources-paths")

    assert Sources.config_paths(project_dir,
             source_paths: ["b.json", Path.join(project_dir, "a.json"), "b.json"]
           ) == [
             Path.join(project_dir, "a.json"),
             Path.join(project_dir, "b.json")
           ]
  after
    cleanup_tmp_dir()
  end

  test "plugin_setting_paths accepts maps, string-keyed maps, and tuple lists" do
    project_dir = tmp_dir("settings-paths")

    assert Sources.plugin_setting_paths(project_dir,
             plugin_setting_paths: [
               %{plugin_id: "beta", path: "settings/beta.json"},
               %{"plugin_id" => "alpha", "path" => "settings/alpha.json"},
               {"alpha", ["settings/alpha.json", "settings/alpha-extra.json"]},
               {:bad, "ignored"}
             ]
           ) == [
             %{
               kind: :plugin_settings,
               plugin_id: "alpha",
               path: Path.join(project_dir, "settings/alpha-extra.json")
             },
             %{
               kind: :plugin_settings,
               plugin_id: "alpha",
               path: Path.join(project_dir, "settings/alpha.json")
             },
             %{
               kind: :plugin_settings,
               plugin_id: "beta",
               path: Path.join(project_dir, "settings/beta.json")
             }
           ]
  after
    cleanup_tmp_dir()
  end

  test "snapshots include checksum for regular files and mark missing files" do
    project_dir = tmp_dir("snapshots")
    path = Path.join(project_dir, "plugin.json")
    File.write!(path, ~s({"plugins":[]}))

    assert [existing, missing] =
             Sources.snapshots([
               %{kind: :plugin_config, path: path},
               %{
                 kind: :plugin_settings,
                 plugin_id: "demo",
                 path: Path.join(project_dir, "missing.json")
               }
             ])

    assert existing.exists?
    assert existing.kind == :plugin_config
    assert is_binary(existing.checksum)
    assert existing.size > 0

    assert missing == %{
             kind: :plugin_settings,
             plugin_id: "demo",
             path: Path.join(project_dir, "missing.json"),
             exists?: false
           }
  after
    cleanup_tmp_dir()
  end

  defp tmp_dir(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-config-watcher-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Process.put(:tmp_dir, dir)
    dir
  end

  defp cleanup_tmp_dir do
    if dir = Process.get(:tmp_dir) do
      File.rm_rf!(dir)
      Process.delete(:tmp_dir)
    end
  end
end
