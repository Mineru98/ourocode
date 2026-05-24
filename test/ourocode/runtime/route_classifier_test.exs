defmodule Ourocode.Runtime.RouteClassifierTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.RouteClassifier

  test "normalizes task input and tokenizes route terms" do
    assert RouteClassifier.normalize_task_input("  MCP\n tools/call\t over HTTP  ") ==
             "MCP tools/call over HTTP"

    assert RouteClassifier.route_tokens("MCP tools/call over streamable HTTP!") == [
             "mcp",
             "tools/call",
             "over",
             "streamable",
             "http"
           ]
  end

  test "classifies MCP flows and transport hints" do
    assert RouteClassifier.routing_decision("MCP tools/call over streamable HTTP") == %{
             kind: :mcp_flow,
             execution_route: :mcp_flow,
             runtime_source: :mcp,
             transport: :streamable_http,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :mcp_flow_terms
           }
  end

  test "classifies explicit Ouroboros workflow shortcuts with adapter route" do
    assert RouteClassifier.routing_decision("ooo run seed_path=seed.md") == %{
             kind: :ouroboros_workflow,
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :explicit_ouroboros_shortcut,
             adapter_route: :run
           }
  end

  test "classifies natural Ouroboros workflow terms" do
    assert %{
             execution_route: :ouroboros_workflow,
             adapter_route: :evolve,
             advanced_shortcut?: false,
             reason: :ouroboros_workflow_terms
           } = RouteClassifier.routing_decision("Run Ouroboros workflow evolve")
  end

  test "classifies explicit runtime shortcuts" do
    assert %{
             execution_route: :runtime,
             runtime_source: :codex,
             advanced_shortcut?: true,
             reason: :explicit_codex_shortcut
           } = RouteClassifier.routing_decision("codex fix failing tests")

    assert %{
             execution_route: :runtime,
             runtime_source: :claude_code,
             reason: :explicit_claude_code_shortcut
           } = RouteClassifier.routing_decision("claude inspect logs")
  end

  test "defaults natural language to auto runtime" do
    assert RouteClassifier.routing_decision("Fix the renderer state bug") == %{
             kind: :runtime,
             execution_route: :runtime,
             runtime_source: :auto,
             transport: :auto,
             requires_command_syntax?: false,
             advanced_shortcut?: false,
             reason: :default_natural_language_runtime
           }
  end
end
