defmodule Ourocode.Runtime.LoopBindingEventFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.LoopBindingEventFlow
  alias Ourocode.Runtime.LoopBindingState

  test "enqueue folds events and poll_fun drains them FIFO" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    first = %{type: :test_event, event_seq: 1}
    second = %{type: :test_event, event_seq: 2}

    assert :ok = LoopBindingEventFlow.enqueue(agent, first)
    assert :ok = LoopBindingEventFlow.enqueue(agent, second)

    poll = LoopBindingEventFlow.poll_fun(agent)

    assert {:ok, ^first} = poll.(%{})
    assert {:ok, ^second} = poll.(%{})
    assert :none = poll.(%{})
  end

  test "enqueue folds MCP parent and child events into topology" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    assert :ok =
             LoopBindingEventFlow.enqueue(agent, %{
               type: :parent_call_started,
               parent_call_id: "parent-flow-1",
               runtime_source: "ouroboros",
               transport: :streamable_http,
               event_seq: 1,
               occurred_at_ms: 101
             })

    assert :ok =
             LoopBindingEventFlow.enqueue(agent, %{
               type: :parent_call_event,
               parent_call_id: "parent-flow-1",
               runtime_source: "ouroboros",
               transport: :streamable_http,
               event_seq: 2,
               occurred_at_ms: 102,
               notification: %{"params" => %{"childID" => "child-flow-1", "token" => "hi"}}
             })

    state = Agent.get(agent, & &1)

    assert [%{parent_call_id: "parent-flow-1"}] = state.parent.working
    assert [%{child_id: "child-flow-1"}] = state.child.working

    assert %{
             "mcp-parent:parent-flow-1->child-session:child-flow-1" => %{
               child_id: "child-flow-1",
               parent_call_id: "parent-flow-1"
             }
           } = state.mcp_topology.edges

    assert %{status: :streaming} = state.acp.tool_calls["parent-flow-1"]
    assert %{parent_call_id: "parent-flow-1"} = state.acp.agent_sessions["child-flow-1"]
  end

  test "enqueue promotes MCP permission requests into wonderTool state" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    assert :ok =
             LoopBindingEventFlow.enqueue(agent, %{
               type: :parent_call_event,
               parent_call_id: "parent-permission-flow-1",
               runtime_source: "grok",
               transport: :stdio,
               event_seq: 3,
               occurred_at_ms: 103,
               notification: %{
                 "method" => "session/request_permission",
                 "params" => %{
                   "requestId" => "perm-flow-1",
                   "childID" => "child-permission-flow-1",
                   "description" => "Apply patch?"
                 }
               }
             })

    state = Agent.get(agent, & &1)

    assert %{
             tool: :wonder_tool,
             request_id: "perm-flow-1",
             parent_call_id: "parent-permission-flow-1",
             child_id: "child-permission-flow-1"
           } = state.wonder
  end

  test "enqueue folds workflow harness events into workflow and ACP state" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    event = %{
      type: :workflow_run_started,
      workflow_run_id: "workflow-run:parent-flow-workflow",
      parent_call_id: "parent-flow-workflow",
      runtime_source: "ourocode",
      transport: :local,
      route: :ouroboros_workflow,
      adapter_route: :run,
      status: :dispatching,
      occurred_at_ms: 42
    }

    assert :ok = LoopBindingEventFlow.enqueue(agent, event)

    state = Agent.get(agent, & &1)

    assert %{status: :dispatching, adapter_route: :run} =
             state.workflow.runs["workflow-run:parent-flow-workflow"]

    assert %{status: :dispatching, adapter_route: :run} =
             state.acp.workflow_runs["workflow-run:parent-flow-workflow"]

    complete = %{
      type: :workflow_run_completed,
      workflow_run_id: "workflow-run:parent-flow-workflow",
      parent_call_id: "parent-flow-workflow",
      runtime_source: "ourocode",
      transport: :local,
      status: :completed,
      occurred_at_ms: 43
    }

    assert :ok = LoopBindingEventFlow.enqueue(agent, complete)

    state = Agent.get(agent, & &1)

    assert %{status: :completed} = state.workflow.runs["workflow-run:parent-flow-workflow"]
    assert %{status: :completed} = state.acp.workflow_runs["workflow-run:parent-flow-workflow"]
  end

  test "runtime_event_fun keeps event-loop bookkeeping hook a no-op" do
    handler = LoopBindingEventFlow.runtime_event_fun(self())

    assert handler.(%{type: :anything}, %{}) == :ok
  end
end
