defmodule Ourocode.Runtime.Dispatcher.RouteResolutionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Adapter
  alias Ourocode.Runtime.Dispatcher.RouteResolution
  alias Ourocode.TaskRequest

  defmodule RuntimeAdapter do
    @behaviour Adapter

    @impl true
    def execute(_task_request, _context), do: {:ok, :runtime}
  end

  defmodule InvalidAdapter do
  end

  test "validates supported runtime routing decisions" do
    assert RouteResolution.validate_decision(%{
             kind: :runtime,
             execution_route: :runtime,
             runtime_source: :auto,
             transport: :auto
           }) == :ok
  end

  test "rejects malformed and mismatched routing decisions" do
    assert RouteResolution.validate_decision(%{
             kind: :runtime,
             execution_route: :mcp_flow,
             runtime_source: :codex,
             transport: :stdio
           }) == {:error, {:route_mismatch, :runtime, :mcp_flow}}

    assert RouteResolution.validate_decision(%{
             kind: :runtime,
             execution_route: :runtime,
             runtime_source: "codex",
             transport: :auto
           }) == {:error, {:invalid_routing_decision, :runtime_source, "codex"}}
  end

  test "validates adapter_route only for ouroboros workflow decisions" do
    assert RouteResolution.validate_decision(%{
             kind: :ouroboros_workflow,
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             transport: :auto,
             adapter_route: :interview
           }) == :ok

    assert RouteResolution.validate_decision(%{
             kind: :runtime,
             execution_route: :runtime,
             runtime_source: :auto,
             transport: :auto,
             adapter_route: :interview
           }) == {:error, {:unexpected_adapter_route, :interview}}
  end

  test "orders adapter keys by most-specific route first" do
    assert RouteResolution.adapter_keys(%{
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             adapter_route: :run
           }) == [
             {:ouroboros_workflow, :run},
             {:ouroboros, :run},
             :ouroboros_run,
             :ouroboros,
             :ouroboros_workflow
           ]

    assert RouteResolution.adapter_keys(%{
             execution_route: :mcp_flow,
             runtime_source: :mcp,
             transport: :sse
           }) == [{:mcp_flow, :sse}, {:mcp, :sse}, :mcp_sse, :mcp, :mcp_flow]
  end

  test "resolves the first registered adapter and reports unsupported tasks" do
    task_request = task_request()
    decision = %{execution_route: :runtime, runtime_source: :auto, transport: :auto}

    assert RouteResolution.resolve_adapter(task_request, decision, %{runtime: RuntimeAdapter}) ==
             {:ok, RuntimeAdapter}

    assert {:error,
            %{
              code: :unsupported_task,
              attempted_adapter_keys: [:runtime],
              message:
                "Unsupported task: no internal runtime flow is available for auto using auto."
            }} = RouteResolution.resolve_adapter(task_request, decision, %{})
  end

  test "validates adapter modules" do
    assert RouteResolution.ensure_adapter(RuntimeAdapter) == :ok

    assert RouteResolution.ensure_adapter(InvalidAdapter) ==
             {:error, {:invalid_adapter, InvalidAdapter}}

    assert RouteResolution.ensure_adapter(:not_a_module) ==
             {:error, {:invalid_adapter, :not_a_module}}
  end

  defp task_request do
    %TaskRequest{
      id: "task-1",
      source: :cli,
      task_input: "inspect",
      submitted_at_ms: 123,
      routing_decision: %{
        kind: :runtime,
        execution_route: :runtime,
        runtime_source: :auto,
        transport: :auto
      }
    }
  end
end
