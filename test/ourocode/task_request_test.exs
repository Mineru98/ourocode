defmodule Ourocode.TaskRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.TaskRequest

  test "parses natural-language task text into an internal request" do
    assert {:ok,
            %TaskRequest{
              id: "task-test",
              source: :cli,
              task_input: "Investigate MCP stream loss and add parser tests",
              submitted_at_ms: 123,
              external_ids: %{},
              wonder_decisions: [],
              routing_decision: %{
                kind: :mcp_flow,
                execution_route: :mcp_flow,
                runtime_source: :mcp,
                transport: :auto,
                requires_command_syntax?: false,
                advanced_shortcut?: false,
                reason: :mcp_flow_terms
              }
            }} =
             TaskRequest.parse("  Investigate MCP stream loss\nand add parser tests  ",
               id: "task-test",
               submitted_at_ms: 123
             )
  end

  test "rejects blank or non-string task input" do
    assert TaskRequest.parse(" \n\t ") == {:error, "task input cannot be blank"}
    assert TaskRequest.parse(nil) == {:error, "task input must be a string"}
  end

  test "parses CLI words as freeform task input without command syntax" do
    assert {:ok,
            %{
              config_args: [],
              task_request: %TaskRequest{
                task_input: "Fix child pane stream recovery",
                routing_decision: %{requires_command_syntax?: false}
              }
            }} =
             TaskRequest.parse_cli_args(["Fix", "child", "pane", "stream", "recovery"],
               id: "task-cli",
               submitted_at_ms: 456
             )
  end

  test "keeps leading config overrides separate from the submitted task" do
    assert {:ok,
            %{
              config_args: [
                "--parallel-child-count",
                "4",
                "--cleanup-policy.allowed-memory-growth-mb=128"
              ],
              task_request: %TaskRequest{
                task_input: "Review token cursor recovery"
              }
            }} =
             TaskRequest.parse_cli_args(
               [
                 "--parallel-child-count",
                 "4",
                 "--cleanup-policy.allowed-memory-growth-mb=128",
                 "Review",
                 "token",
                 "cursor",
                 "recovery"
               ],
               id: "task-with-config",
               submitted_at_ms: 789
             )
  end

  test "supports explicit delimiter before natural-language task text" do
    assert {:ok,
            %{
              config_args: ["--repeat-count=2"],
              task_request: %TaskRequest{task_input: "Compare stdio and SSE streams"}
            }} =
             TaskRequest.parse_cli_args(
               ["--repeat-count=2", "--", "Compare", "stdio", "and", "SSE", "streams"],
               id: "task-delimited",
               submitted_at_ms: 101
             )
  end

  test "marks explicit runtime commands only as advanced shortcuts" do
    assert {:ok,
            %TaskRequest{
              task_input: "codex inspect session recovery",
              routing_decision: %{
                kind: :runtime,
                execution_route: :runtime,
                runtime_source: :codex,
                transport: :auto,
                requires_command_syntax?: false,
                advanced_shortcut?: true,
                reason: :explicit_codex_shortcut
              }
            }} =
             TaskRequest.parse("codex inspect session recovery",
               id: "advanced-shortcut",
               submitted_at_ms: 202
             )
  end

  test "marks explicit diagnostics and test commands as advanced shortcuts" do
    cases = [
      {"diagnostics streams stdio", :stdio, :explicit_diagnostics_shortcut},
      {"test:transports sse seq stream", :sse, :explicit_test_shortcut}
    ]

    for {input, transport, reason} <- cases do
      assert {:ok,
              %TaskRequest{
                routing_decision: %{
                  kind: :runtime,
                  execution_route: :runtime,
                  runtime_source: :auto,
                  transport: ^transport,
                  requires_command_syntax?: false,
                  advanced_shortcut?: true,
                  reason: ^reason
                }
              }} =
               TaskRequest.parse(input,
                 id: "advanced-diagnostic-shortcut",
                 submitted_at_ms: 303
               )
    end
  end

  test "natural-language diagnostics are not treated as product commands" do
    assert {:ok,
            %TaskRequest{
              task_input: "Run diagnostics for stream health",
              routing_decision: %{
                kind: :runtime,
                execution_route: :runtime,
                runtime_source: :auto,
                requires_command_syntax?: false,
                advanced_shortcut?: false,
                reason: :default_natural_language_runtime
              }
            }} =
             TaskRequest.parse("Run diagnostics for stream health",
               id: "natural-diagnostics",
               submitted_at_ms: 404
             )
  end

  test "classifies parsed task requests into exactly one supported route" do
    cases = [
      {"Investigate child pane stream recovery", :runtime, :auto, :auto,
       :default_natural_language_runtime},
      {"opencode focus child session child-1 over SSE", :runtime, :opencode, :sse,
       :explicit_opencode_shortcut},
      {"ooo interview clarify cleanup policy", :ouroboros_workflow, :ouroboros, :auto,
       :explicit_ouroboros_shortcut},
      {"Run Ouroboros workflow evolve for the plugin renderer", :ouroboros_workflow, :ouroboros,
       :auto, :ouroboros_workflow_terms},
      {"MCP tools/call over streamable HTTP", :mcp_flow, :mcp, :streamable_http, :mcp_flow_terms},
      {"Inspect mcp:stdio parent call stream", :mcp_flow, :mcp, :stdio, :mcp_flow_terms}
    ]

    for {input, route, runtime_source, transport, reason} <- cases do
      assert {:ok, %TaskRequest{routing_decision: decision}} =
               TaskRequest.parse(input, id: "route-test", submitted_at_ms: 999)

      assert decision.kind == route
      assert decision.execution_route == route
      assert decision.runtime_source == runtime_source
      assert decision.transport == transport
      assert decision.reason == reason
      assert decision.requires_command_syntax? == false
      assert exactly_one_supported_route?(decision)
    end
  end

  test "annotates Ouroboros workflow routes with adapter route intent" do
    cases = [
      {"ooo auto improve startup", :auto},
      {"ooo interview clarify cleanup policy", :interview},
      {"ooo pm build onboarding", :interview},
      {"ouroboros seed create dispatcher contract", :seed},
      {"ooo run seed_abc123.yaml", :run},
      {"Run Ouroboros workflow evolve for the plugin renderer", :evolve},
      {"ouroboros:ralph repair failing stream test", :ralph}
    ]

    for {input, adapter_route} <- cases do
      assert {:ok, %TaskRequest{routing_decision: decision}} =
               TaskRequest.parse(input, id: "ouroboros-route-test", submitted_at_ms: 1_234)

      assert decision.execution_route == :ouroboros_workflow
      assert decision.runtime_source == :ouroboros
      assert decision.adapter_route == adapter_route
    end
  end

  test "reports unsupported or incomplete leading config flags" do
    assert TaskRequest.parse_cli_args(["--unknown", "Fix", "streams"]) ==
             {:error, "unsupported config override argument: --unknown"}

    assert TaskRequest.parse_cli_args(["--parallel-child-count"]) ==
             {:error, "missing value for config override argument: --parallel-child-count"}
  end

  defp exactly_one_supported_route?(%{kind: kind, execution_route: execution_route}) do
    supported_routes = [:runtime, :ouroboros_workflow, :mcp_flow]

    kind in supported_routes and execution_route == kind
  end
end
