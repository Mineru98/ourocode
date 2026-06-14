defmodule Ourocode.Runtime.McpDaemon.CommandTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.McpDaemon.Command

  test "prefers uvx with pinned ouroboros extras" do
    finder = finder(%{"uvx" => "/bin/uvx", "ouroboros" => "/bin/ouroboros"})

    assert {"/bin/uvx", args} = Command.build("127.0.0.1", 4321, nil, finder)

    assert args ==
             [
               "--from",
               "ouroboros-ai[mcp,claude]",
               "ouroboros",
               "mcp",
               "serve",
               "--transport",
               "streamable-http",
               "--host",
               "127.0.0.1",
               "--port",
               "4321",
               "--runtime",
               "claude"
             ]
  end

  test "falls back to bare ouroboros when uvx is unavailable" do
    finder = finder(%{"ouroboros" => "/bin/ouroboros"})

    assert {"/bin/ouroboros", args} = Command.build("0.0.0.0", 4000, "", finder)

    assert args == [
             "mcp",
             "serve",
             "--transport",
             "streamable-http",
             "--host",
             "0.0.0.0",
             "--port",
             "4000",
             "--runtime",
             "claude"
           ]
  end

  test "adds runtime-specific backend args" do
    finder = finder(%{"uvx" => "/bin/uvx"})

    assert {_exe, args} = Command.build("127.0.0.1", 4001, "codex", finder)
    assert Enum.slice(args, -4, 4) == ["--runtime", "codex", "--llm-backend", "codex"]

    assert {_exe, args} = Command.build("127.0.0.1", 4001, "opencode", finder)
    assert Enum.slice(args, -4, 4) == ["--runtime", "claude", "--llm-backend", "opencode"]

    assert {_exe, args} = Command.build("127.0.0.1", 4001, "claude_code", finder)
    assert Enum.slice(args, -4, 4) == ["--runtime", "claude", "--llm-backend", "claude_code"]

    assert {_exe, args} = Command.build("127.0.0.1", 4001, "gemini", finder)
    assert Enum.slice(args, -4, 4) == ["--runtime", "claude", "--llm-backend", "gemini"]
  end

  test "adds generic backend args and reports unavailable commands" do
    assert {_exe, args} =
             Command.build("127.0.0.1", 4002, :custom, finder(%{"uvx" => "/bin/uvx"}))

    assert Enum.slice(args, -4, 4) == ["--runtime", "claude", "--llm-backend", "custom"]

    assert Command.build("127.0.0.1", 4002, nil, finder(%{})) == :none
  end

  defp finder(commands) do
    fn name -> Map.get(commands, name) end
  end
end
