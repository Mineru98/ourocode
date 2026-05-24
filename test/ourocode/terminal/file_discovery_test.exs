defmodule Ourocode.Terminal.FileDiscoveryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.FileDiscovery

  test "parse_rg_files filters build, deps, and git paths" do
    assert FileDiscovery.parse_rg_files("""
           lib/ourocode/terminal/tui.ex
           deps/jason/lib/jason.ex
           apps/core/_build/dev/cache
           .git/config
           test/ourocode/terminal/tui_test.exs
           """) == [
             "lib/ourocode/terminal/tui.ex",
             "test/ourocode/terminal/tui_test.exs"
           ]
  end

  test "discover returns no files when rg is unavailable" do
    assert FileDiscovery.discover(find_executable: fn "rg" -> nil end) == []
  end

  test "discover runs rg files and parses successful output" do
    cmd = fn "rg", ["--files"], opts ->
      assert opts[:cd] == "/project"
      assert opts[:stderr_to_stdout] == true
      {"lib/a.ex\n_build/ignored\n", 0}
    end

    assert FileDiscovery.discover(
             cwd: "/project",
             find_executable: fn "rg" -> "/bin/rg" end,
             cmd: cmd
           ) == ["lib/a.ex"]
  end

  test "discover ignores command failures" do
    assert FileDiscovery.discover(
             find_executable: fn "rg" -> "/bin/rg" end,
             cmd: fn "rg", ["--files"], _opts -> {"boom", 2} end
           ) == []
  end
end
