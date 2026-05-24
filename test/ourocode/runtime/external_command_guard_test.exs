defmodule Ourocode.Runtime.ExternalCommandGuardTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.ExternalCommandGuard

  test "rejects direct agent command execution by executable basename" do
    assert ExternalCommandGuard.ensure_allowed("/usr/local/bin/codex", ["exec"]) ==
             {:error, {:forbidden_external_command, "codex"}}

    assert ExternalCommandGuard.ensure_allowed("claude-code", ["--print"]) ==
             {:error, {:forbidden_external_command, "claude-code"}}
  end

  test "rejects shell-wrapped agent commands in shell arguments" do
    assert ExternalCommandGuard.ensure_allowed("sh", ["-c", "claude-code --print inspect"]) ==
             {:error, {:forbidden_external_command, :shell_wrapped_agent_command}}

    assert ExternalCommandGuard.ensure_allowed("zsh", ["-lc", "codex exec task"]) ==
             {:error, {:forbidden_external_command, :shell_wrapped_agent_command}}
  end

  test "does not reject agent command names embedded in larger tokens" do
    assert ExternalCommandGuard.ensure_allowed("sh", ["-c", "my-codex-helper scan"]) == :ok
  end

  test "permits non-agent helper commands" do
    assert ExternalCommandGuard.ensure_allowed("/usr/local/bin/ourocode-helper", ["scan"]) == :ok
  end

  test "guarded_runner validates before delegating and preserves allowed calls" do
    me = self()

    runner =
      ExternalCommandGuard.guarded_runner(fn command, args, opts ->
        send(me, {:called, command, args, opts})
        {:ok, command}
      end)

    assert runner.("codex", ["exec"], []) == {:error, {:forbidden_external_command, "codex"}}
    refute_received {:called, _, _, _}

    assert runner.("helper", ["scan"], timeout: 10) == {:ok, "helper"}
    assert_received {:called, "helper", ["scan"], [timeout: 10]}
  end

  test "guarded_runner returns not configured only after validation passes" do
    runner = ExternalCommandGuard.guarded_runner(nil)

    assert runner.("helper", ["scan"], []) == {:error, :external_command_runner_not_configured}
    assert runner.("codex", ["exec"], []) == {:error, {:forbidden_external_command, "codex"}}
  end
end
