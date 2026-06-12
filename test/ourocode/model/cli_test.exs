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

  test "retries a run that fails before emitting any output" do
    tmp_dir = tmp_dir!()
    marker = Path.join(tmp_dir, "ran-once")
    claude_path = Path.join(tmp_dir, "claude")

    # Fails silently on the first launch, echoes the prompt on the second.
    File.write!(claude_path, """
    #!/bin/sh
    if [ -f "#{marker}" ]; then printf '%s' "$2"; else touch "#{marker}"; exit 1; fi
    """)

    File.chmod!(claude_path, 0o755)

    assert {:ok, "hello"} =
             Cli.stream(
               :claude,
               "hello",
               [which: fn "claude" -> claude_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.exists?(marker)
  end

  test "does not retry once output has reached the renderer" do
    tmp_dir = tmp_dir!()
    count = Path.join(tmp_dir, "count")
    claude_path = Path.join(tmp_dir, "claude")

    File.write!(claude_path, """
    #!/bin/sh
    echo run >> "#{count}"
    printf 'partial '
    exit 1
    """)

    File.chmod!(claude_path, 0o755)

    assert {:error, {:exit, 1}} =
             Cli.stream(
               :claude,
               "hello",
               [which: fn "claude" -> claude_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.read!(count) == "run\n"
  end

  test "a persistent silent failure surfaces after the retry budget" do
    tmp_dir = tmp_dir!()
    count = Path.join(tmp_dir, "count")
    claude_path = Path.join(tmp_dir, "claude")

    File.write!(claude_path, """
    #!/bin/sh
    echo run >> "#{count}"
    exit 7
    """)

    File.chmod!(claude_path, 0o755)

    assert {:error, {:exit, 7}} =
             Cli.stream(
               :claude,
               "hello",
               [which: fn "claude" -> claude_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.read!(count) == "run\nrun\nrun\n"
  end

  defp tmp_dir! do
    tmp_dir =
      Path.join(System.tmp_dir!(), "ourocode-cli-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    tmp_dir
  end
end
