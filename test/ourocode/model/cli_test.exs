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

  test "claude args request streamed partial messages" do
    args = Cli.args(:claude, "Return ready")

    assert List.last(args) == "Return ready"
    assert "--output-format" in args
    assert "stream-json" in args
    assert "--include-partial-messages" in args
  end

  test "claude args inject the ourocode identity via --append-system-prompt" do
    args = Cli.args(:claude, "hi", "You are ourocode.")

    assert "--append-system-prompt" in args
    idx = Enum.find_index(args, &(&1 == "--append-system-prompt"))
    assert Enum.at(args, idx + 1) == "You are ourocode."
    # The prompt stays last so the system text is a flag, not the message.
    assert List.last(args) == "hi"
  end

  test "codex and gemini args ignore the system prompt (no equivalent flag)" do
    refute "--append-system-prompt" in Cli.args(:codex_cli, "hi", "You are ourocode.")
    refute "--append-system-prompt" in Cli.args(:gemini, "hi", "You are ourocode.")
  end

  test "claude stream surfaces text deltas and ignores system noise" do
    tmp_dir = tmp_dir!()
    claude_path = Path.join(tmp_dir, "claude")

    # Recorded shapes from `claude -p --output-format stream-json
    # --include-partial-messages --verbose`.
    File.write!(claude_path, """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","cwd":"/tmp"}'
    printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}'
    printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi! "}}}'
    printf '%s\\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"there"}}}'
    printf '%s\\n' '{"type":"result","subtype":"success","result":"Hi! there"}'
    """)

    File.chmod!(claude_path, 0o755)

    parent = self()

    assert {:ok, "Hi! there"} =
             Cli.stream(
               :claude,
               "say hi",
               [which: fn "claude" -> claude_path end],
               fn chunk -> send(parent, {:chunk, chunk}) end
             )

    assert_received {:chunk, "Hi! "}
    assert_received {:chunk, "there"}
    refute_received {:chunk, _other}
  end

  test "claude stream falls back to the result event when no deltas arrived" do
    tmp_dir = tmp_dir!()
    claude_path = Path.join(tmp_dir, "claude")

    File.write!(claude_path, """
    #!/bin/sh
    printf '%s\\n' '{"type":"result","subtype":"success","result":"only the result"}'
    """)

    File.chmod!(claude_path, 0o755)

    assert {:ok, "only the result"} =
             Cli.stream(
               :claude,
               "say hi",
               [which: fn "claude" -> claude_path end],
               fn _chunk -> :ok end
             )
  end

  test "retries a run that fails before emitting any output" do
    tmp_dir = tmp_dir!()
    marker = Path.join(tmp_dir, "ran-once")
    gemini_path = Path.join(tmp_dir, "gemini")

    # Fails silently on the first launch, echoes the prompt on the second.
    File.write!(gemini_path, """
    #!/bin/sh
    if [ -f "#{marker}" ]; then printf '%s' "$2"; else touch "#{marker}"; exit 1; fi
    """)

    File.chmod!(gemini_path, 0o755)

    assert {:ok, "hello"} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.exists?(marker)
  end

  test "does not retry once output has reached the renderer" do
    tmp_dir = tmp_dir!()
    count = Path.join(tmp_dir, "count")
    gemini_path = Path.join(tmp_dir, "gemini")

    File.write!(gemini_path, """
    #!/bin/sh
    echo run >> "#{count}"
    printf 'partial '
    exit 1
    """)

    File.chmod!(gemini_path, 0o755)

    assert {:error, {:exit, 1}} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1],
               fn _chunk -> :ok end
             )

    assert File.read!(count) == "run\n"
  end

  test "a persistent silent failure surfaces after the retry budget" do
    tmp_dir = tmp_dir!()
    count = Path.join(tmp_dir, "count")
    gemini_path = Path.join(tmp_dir, "gemini")

    File.write!(gemini_path, """
    #!/bin/sh
    echo run >> "#{count}"
    exit 7
    """)

    File.chmod!(gemini_path, 0o755)

    assert {:error, {:exit, 7}} =
             Cli.stream(
               :gemini,
               "hello",
               [which: fn "gemini" -> gemini_path end, retry_base_delay_ms: 1],
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
