defmodule Ourocode.Command.Registry.SourcesTest do
  use ExUnit.Case, async: false

  alias Ourocode.Command.Registry
  alias Ourocode.Command.Registry.Sources

  setup do
    previous = System.get_env("OUROCODE_SKILL_DIRS")

    on_exit(fn ->
      if previous do
        System.put_env("OUROCODE_SKILL_DIRS", previous)
      else
        System.delete_env("OUROCODE_SKILL_DIRS")
      end
    end)
  end

  test "skill_dirs prefers explicit opts over environment defaults" do
    System.put_env("OUROCODE_SKILL_DIRS", "/env/one#{Sources.path_separator()}/env/two")

    assert Sources.skill_dirs(skill_dirs: ["/explicit"]) == ["/explicit"]
  end

  test "default_skill_dirs reads OUROCODE_SKILL_DIRS and supports an empty override" do
    System.put_env("OUROCODE_SKILL_DIRS", "/env/one#{Sources.path_separator()}/env/two")
    assert Sources.default_skill_dirs() == ["/env/one", "/env/two"]

    System.put_env("OUROCODE_SKILL_DIRS", "")
    assert Sources.default_skill_dirs() == []
  end

  test "plugin_config keeps plugin_config precedence over legacy plugins opt" do
    assert Sources.plugin_config(plugin_config: :config, plugins: [:legacy]) == :config
    assert Sources.plugin_config(plugins: [:legacy]) == [:legacy]
    assert Sources.plugin_config([]) == []
  end

  test "load merges sources in builtin, bundled, local, plugin, mcp order" do
    bundled_root = unique_tmp_dir("bundled")
    local_root = unique_tmp_dir("local")

    write_skill(bundled_root, "bundled-flow")
    write_skill(local_root, "local-flow")

    {:ok, builtin_registry} = Registry.load_builtin()

    assert {:ok, registry} =
             Sources.load(
               [
                 bundled_skill_dirs: [bundled_root],
                 skill_dirs: [local_root],
                 plugins: [],
                 mcp_entries: []
               ],
               builtin_registry
             )

    assert registry.sources == [:builtin, :bundled_skill, :local]
    assert {:ok, bundled} = Registry.fetch(registry, "/bundled-flow")
    assert {:ok, local} = Registry.fetch(registry, "/local-flow")
    assert bundled.source == :bundled_skill
    assert local.source == :local
  after
    cleanup_tmp_dirs()
  end

  defp write_skill(root, name) do
    skill_dir = Path.join(root, name)
    File.mkdir_p!(skill_dir)

    File.write!(Path.join(skill_dir, "SKILL.md"), """
    ---
    name: "#{name}"
    description: "#{name} skill."
    ---
    """)
  end

  defp unique_tmp_dir(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-registry-sources-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Process.put(:tmp_dirs, [dir | Process.get(:tmp_dirs, [])])
    dir
  end

  defp cleanup_tmp_dirs do
    Process.get(:tmp_dirs, [])
    |> Enum.each(&File.rm_rf!/1)

    Process.delete(:tmp_dirs)
  end
end
