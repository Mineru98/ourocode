defmodule Ourocode.Runtime.McpDaemonBindingTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Runtime.McpDaemonBinding

  test "maps selected models to MCP LLM backend identifiers" do
    assert McpDaemonBinding.llm_backend(model(:codex)) == "codex"
    assert McpDaemonBinding.llm_backend(model(:codex_cli)) == "codex"
    assert McpDaemonBinding.llm_backend(model(:claude)) == "claude_code"
  end

  test "reuses external daemons and matching backend handles" do
    assert McpDaemonBinding.reusable?(nil, "codex", "codex") == false
    assert McpDaemonBinding.reusable?(%{mode: :external}, "codex", "claude_code") == true
    assert McpDaemonBinding.reusable?(%{mode: :managed}, "codex", "codex") == true
    assert McpDaemonBinding.reusable?(%{mode: :managed}, "codex", "claude_code") == false
  end

  test "resets Ouroboros log sources and activity" do
    state = %{
      ouroboros_log_paths: ["old.log"],
      ouroboros_log_offsets: %{"old.log" => 10},
      ouroboros_activity: ["old"]
    }

    updated = McpDaemonBinding.reset_log_sources(state, %{log_path: "new.log"})

    assert "new.log" in updated.ouroboros_log_paths
    assert Map.has_key?(updated.ouroboros_log_offsets, "new.log")
    assert updated.ouroboros_activity == []
  end

  defp model(id) do
    %Model{id: id, label: to_string(id), kind: :cli, status: :ready, run: fn _, _, _ -> :ok end}
  end
end
