defmodule Ourocode.Plugin.HotReloadCompilerTest do
  use ExUnit.Case, async: false

  alias Ourocode.Plugin.HotReloadCompiler

  test "returns ok when there are no changed sources" do
    assert HotReloadCompiler.compile_changed_sources(compile_paths: []) == :ok
  end

  test "rejects non-binary compile paths" do
    assert HotReloadCompiler.compile_changed_sources(compile_paths: [:not_a_path]) ==
             {:error, {:invalid_compile_path, :not_a_path}}
  end

  test "rejects source paths outside allowed roots" do
    allowed_root = tmp_dir!("allowed")
    disallowed_root = tmp_dir!("disallowed")
    source_path = Path.join(disallowed_root, "plugin.exs")

    File.write!(source_path, "defmodule Ourocode.DisallowedHotReloadSource do\nend\n")

    assert HotReloadCompiler.compile_source(source_path, allowed_roots: [allowed_root]) ==
             {:error, :plugin_path_not_allowed}
  end

  test "compiles source paths under allowed roots" do
    plugin_root = tmp_dir!("compile")
    module_name = "Ourocode.HotReloadCompilerCompiled#{System.unique_integer([:positive])}"
    source_path = Path.join(plugin_root, "compiled.exs")

    File.write!(
      source_path,
      """
      defmodule #{module_name} do
        def compiled?, do: true
      end
      """
    )

    assert HotReloadCompiler.compile_changed_sources(
             compile_paths: [source_path],
             allowed_roots: [plugin_root]
           ) == :ok

    assert apply(Module.concat([module_name]), :compiled?, []) == true
  end

  test "reports compile failures without raising" do
    plugin_root = tmp_dir!("compile-failure")
    source_path = Path.join(plugin_root, "broken.exs")

    File.write!(source_path, "defmodule BrokenHotReloadSource do\n  def broken(\nend\n")

    assert {:error, {:compile_failed, ^source_path, message}} =
             HotReloadCompiler.compile_source(source_path, allowed_roots: [plugin_root])

    assert is_binary(message)
    assert message != ""
  end

  defp tmp_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-hot-reload-compiler-test-#{name}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
