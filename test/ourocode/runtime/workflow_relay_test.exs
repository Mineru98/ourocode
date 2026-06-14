defmodule Ourocode.Runtime.WorkflowRelayTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Json

  alias Ourocode.Runtime.{
    Dispatcher,
    LoopBindingEventFlow,
    LoopBindingState,
    WorkflowRelay
  }

  defp drain_inbox(agent) do
    poll = LoopBindingEventFlow.poll_fun(agent)

    Stream.repeatedly(fn -> poll.(%{}) end)
    |> Enum.take_while(&match?({:ok, _event}, &1))
    |> Enum.map(fn {:ok, event} -> event end)
  end

  test "captures background workflow handles from starter response metadata" do
    {:ok, agent} = Agent.start_link(fn -> %{workflow: %{}, child: ChildSessionPanes.new()} end)

    result = %ParentCallResult{
      parent_call_id: "parent-auto-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"job_id" => "job-auto-1"},
      response: %{
        "result" => %{
          "meta" => %{
            "auto_session_id" => "auto-1",
            "session_id" => "session-1",
            "execution_id" => "exec-1",
            "lineage_id" => "lin-1"
          },
          "content" => [%{"type" => "text", "text" => "Auto started"}]
        }
      }
    }

    assert :ok = WorkflowRelay.capture_workflow_result(agent, result, File.cwd!())

    workflow = Agent.get(agent, & &1.workflow)

    assert workflow.latest_job_id == "job-auto-1"
    assert workflow.latest_auto_session_id == "auto-1"
    assert workflow.latest_workflow_session_id == "session-1"
    assert workflow.latest_execution_id == "exec-1"
    assert workflow.latest_lineage_id == "lin-1"

    rendered_child =
      agent
      |> Agent.get(& &1.child)
      |> ChildSessionPanes.render()

    assert rendered_child.focused == "child-session:job-auto-1"

    assert [
             %{
               id: "child-session:job-auto-1",
               child_id: "job-auto-1",
               parent_call_id: "parent-auto-1",
               external_ids: %{
                 "job_id" => "job-auto-1",
                 "auto_session_id" => "auto-1",
                 "session_id" => "session-1",
                 "execution_id" => "exec-1",
                 "lineage_id" => "lin-1"
               }
             }
           ] = rendered_child.working

    pane_model = %{panes: Map.new(rendered_child.working, &{&1.id, &1}), open: rendered_child.open}

    input_event = %{
      type: :prompt_input_submitted,
      task_request_id: "task-steer-auto-1",
      task_input: "continue the auto run with stricter acceptance criteria",
      focused_pane: "child-session:job-auto-1",
      steering_target: :child,
      steering_target_pane_id: "child-session:job-auto-1",
      steering_target_session_id: "job-auto-1",
      steering_target_kind: :child_session,
      steering_text: "continue the auto run with stricter acceptance criteria",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:job-auto-1",
        target_session_id: "job-auto-1",
        target_kind: :child_session,
        content: "continue the auto run with stricter acceptance criteria"
      }
    }

    dispatcher = fn pane, serialized_message, context ->
      send(self(), {:steered_background_job, pane, serialized_message, context})
      {:ok, :delivered}
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:job-auto-1", child_id: "job-auto-1"},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :delivered
            }} =
             Dispatcher.dispatch_steering_message(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher
             )

    assert_receive {:steered_background_job, %{id: "child-session:job-auto-1"},
                    ^serialized_message, %{decoded_message: ^decoded_message}}

    assert {:ok, wire_message} = Json.decode(serialized_message)
    assert wire_message["type"] == "pane_directed_steering_message"
    assert wire_message["target_pane_id"] == "child-session:job-auto-1"
    assert wire_message["target_session_id"] == "job-auto-1"
    assert wire_message["child_id"] == "job-auto-1"
    assert wire_message["content"] == "continue the auto run with stricter acceptance criteria"
  end

  test "run relays streamed events and completes when the worker returns" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    event = %{
      type: :parent_call_event,
      event_seq: 1,
      parent_call_id: "parent-run-ok-1",
      transport: :streamable_http,
      runtime_source: "ouroboros"
    }

    assert :ok =
             WorkflowRelay.run(
               agent,
               %{},
               "parent-run-ok-1",
               %{"name" => "ooo.run"},
               File.cwd!(),
               "http://127.0.0.1:4000/mcp",
               execute_parent_call: fn opts, _payload ->
                 send(opts[:subscriber], {:ourocode_event, event})

                 {:ok,
                  %ParentCallResult{
                    parent_call_id: opts[:parent_call_id],
                    runtime_source: "ouroboros",
                    transport: :streamable_http,
                    external_ids: %{},
                    response: %{"result" => %{"content" => []}}
                  }}
               end,
               flush: fn _agent -> :ok end
             )

    assert [^event, completed] = drain_inbox(agent)
    assert completed.type == :workflow_run_completed
    assert completed.parent_call_id == "parent-run-ok-1"
    assert completed.reason == "relay_completed"
  end

  test "run enqueues failure events when the worker dies before reporting" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    assert :ok =
             WorkflowRelay.run(
               agent,
               %{},
               "parent-run-crash-1",
               %{"name" => "ooo.run"},
               File.cwd!(),
               "http://127.0.0.1:4000/mcp",
               execute_parent_call: fn _opts, _payload -> Process.exit(self(), :boom) end,
               flush: fn _agent -> :ok end
             )

    assert [parent_failed, run_failed] = drain_inbox(agent)

    assert parent_failed.type == :parent_call_failed
    assert parent_failed.parent_call_id == "parent-run-crash-1"
    assert parent_failed.payload.reason =~ "relay_worker_exit"
    assert parent_failed.payload.reason =~ "boom"

    assert run_failed.type == :workflow_run_failed
    assert run_failed.parent_call_id == "parent-run-crash-1"
    assert run_failed.reason =~ "relay_worker_exit"
  end

  test "run kills the worker and enqueues failure events on timeout" do
    {:ok, agent} = Agent.start_link(&LoopBindingState.initial/0)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    test_pid = self()

    assert :ok =
             WorkflowRelay.run(
               agent,
               %{},
               "parent-run-timeout-1",
               %{"name" => "ooo.run"},
               File.cwd!(),
               "http://127.0.0.1:4000/mcp",
               execute_parent_call: fn _opts, _payload ->
                 send(test_pid, {:worker_started, self()})

                 receive do
                   :never -> :ok
                 end
               end,
               flush: fn _agent -> :ok end,
               timeout: 20
             )

    assert_receive {:worker_started, worker}, 100
    Process.sleep(10)
    refute Process.alive?(worker)

    assert [parent_failed, run_failed] = drain_inbox(agent)

    assert parent_failed.type == :parent_call_failed
    assert parent_failed.payload.reason =~ "relay_worker_timeout"

    assert run_failed.type == :workflow_run_failed
    assert run_failed.reason =~ "relay_worker_timeout"
  end

  test "capture_workflow_result starts the child status poller for job-backed children" do
    {:ok, agent} = Agent.start_link(fn -> %{workflow: %{}, child: ChildSessionPanes.new()} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    result = %ParentCallResult{
      parent_call_id: "parent-poller-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"job_id" => "job-poller-1"},
      response: %{"result" => %{"content" => [%{"type" => "text", "text" => "queued"}]}}
    }

    test_pid = self()

    assert :ok =
             WorkflowRelay.capture_workflow_result(agent, result, File.cwd!(),
               mcp_url: "http://127.0.0.1:4000/mcp",
               poller_starter: fn poller_agent, opts ->
                 send(test_pid, {:poller_started, poller_agent, opts})
                 self()
               end
             )

    assert_receive {:poller_started, ^agent, opts}
    assert opts[:child_id] == "job-poller-1"
    assert opts[:job_id] == "job-poller-1"
    assert opts[:parent_call_id] == "parent-poller-1"
    assert opts[:mcp_url] == "http://127.0.0.1:4000/mcp"
  end

  test "capture_workflow_result skips the poller without an mcp_url or job id" do
    {:ok, agent} = Agent.start_link(fn -> %{workflow: %{}, child: ChildSessionPanes.new()} end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    job_result = %ParentCallResult{
      parent_call_id: "parent-poller-2",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"job_id" => "job-poller-2"},
      response: %{"result" => %{"content" => []}}
    }

    test_pid = self()
    poller_starter = fn _agent, opts -> send(test_pid, {:poller_started, opts}) end

    # Direct capture callers (no mcp_url) never start a poller.
    assert :ok =
             WorkflowRelay.capture_workflow_result(agent, job_result, File.cwd!(),
               poller_starter: poller_starter
             )

    refute_receive {:poller_started, _opts}, 20

    # Children without a job id (auto sessions) are not pollable.
    auto_result = %ParentCallResult{
      parent_call_id: "parent-poller-3",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"auto_session_id" => "auto-poller-3"},
      response: %{"result" => %{"content" => []}}
    }

    assert :ok =
             WorkflowRelay.capture_workflow_result(agent, auto_result, File.cwd!(),
               mcp_url: "http://127.0.0.1:4000/mcp",
               poller_starter: poller_starter
             )

    refute_receive {:poller_started, _opts}, 20
  end
end
