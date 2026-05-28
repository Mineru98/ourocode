defmodule Ourocode.Model.CliTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model.Cli

  test "codex args request JSON events without color" do
    assert Cli.args(:codex_cli, "Return ready") == [
             "exec",
             "--json",
             "--color",
             "never",
             "--ephemeral",
             "--skip-git-repo-check",
             "Return ready"
           ]
  end

  test "codex stream exposes agent message text and returns the final answer" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ourocode-cli-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    codex_path = Path.join(tmp_dir, "codex")

    File.write!(codex_path, """
    #!/bin/sh
    printf 'startup noise\\n'
    printf '{"type":"thread.started","thread_id":"thread-1"}\\n'
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"checking"}}\\n'
    printf '{"type":"item.completed","item":{"type":"agent_message","text":"ready"}}\\n'
    printf 'trailing noise\\n'
    """)

    File.chmod!(codex_path, 0o755)

    parent = self()

    assert {:ok, "ready"} =
             Cli.stream(
               :codex_cli,
               "Return ready",
               [which: fn "codex" -> codex_path end],
               fn chunk -> send(parent, {:chunk, chunk}) end
             )

    assert_received {:chunk, "ready"}
    assert_received {:chunk, "checking"}
    refute_received {:chunk, "startup noise\n"}
  end
end
