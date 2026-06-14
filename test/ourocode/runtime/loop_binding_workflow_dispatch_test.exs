defmodule Ourocode.Runtime.LoopBindingWorkflowDispatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Plugin.UserLevel.Capability
  alias Ourocode.Runtime.LoopBindingWorkflowDispatch
  alias Ourocode.Runtime.LoopBindings
  alias Ourocode.TaskRequest

  test "ouroboros_route? detects workflow-routed task requests only" do
    assert LoopBindingWorkflowDispatch.ouroboros_route?(%{
             routing_decision: %{execution_route: :ouroboros_workflow}
           })

    refute LoopBindingWorkflowDispatch.ouroboros_route?(%{
             routing_decision: %{execution_route: :runtime}
           })

    refute LoopBindingWorkflowDispatch.ouroboros_route?(%{})
  end

  test "user_level_route? detects UserLevel plugin task requests only" do
    assert LoopBindingWorkflowDispatch.user_level_route?(%{
             routing_decision: %{execution_route: :user_level_plugin}
           })

    refute LoopBindingWorkflowDispatch.user_level_route?(%{
             routing_decision: %{execution_route: :ouroboros_workflow}
           })
  end

  test "interview_task? detects interview-shaped adapter routes only" do
    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :interview}
           })

    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :pm}
           })

    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :workflow}
           })

    refute LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :run}
           })
  end

  test "adapter registry maps pm and workflow routes onto the interview invocation" do
    registry = LoopBindingWorkflowDispatch.adapter_registry()

    assert registry[{:ouroboros_workflow, :pm}] == Ourocode.Runtime.InterviewWorkflowInvocation
    assert registry[{:ouroboros, :pm}] == Ourocode.Runtime.InterviewWorkflowInvocation
    assert registry[:ouroboros_pm] == Ourocode.Runtime.InterviewWorkflowInvocation

    assert registry[{:ouroboros_workflow, :workflow}] ==
             Ourocode.Runtime.InterviewWorkflowInvocation

    assert registry[{:ouroboros, :workflow}] == Ourocode.Runtime.InterviewWorkflowInvocation
  end

  test "direct_task? detects non-MCP control routes" do
    assert LoopBindingWorkflowDispatch.direct_task?(%{
             routing_decision: %{adapter_route: :cancel}
           })

    assert LoopBindingWorkflowDispatch.direct_task?(%{
             routing_decision: %{adapter_route: :resume_session}
           })

    refute LoopBindingWorkflowDispatch.direct_task?(%{
             routing_decision: %{adapter_route: :run}
           })
  end

  test "parent_call_id is stable for string and integer ids" do
    assert LoopBindingWorkflowDispatch.parent_call_id(%{id: "abc"}) == "parent-abc"
    assert LoopBindingWorkflowDispatch.parent_call_id(%{id: 42}) == "parent-42"
  end

  test "input_event_model reads atom and string keyed active model" do
    model = %Model{
      id: :codex,
      label: "Codex",
      kind: :oauth,
      status: :ready,
      run: fn _prompt, _opts, _on_chunk -> {:ok, ""} end
    }

    assert LoopBindingWorkflowDispatch.input_event_model(%{active_model: model}) == model
    assert LoopBindingWorkflowDispatch.input_event_model(%{"active_model" => model}) == model
    assert LoopBindingWorkflowDispatch.input_event_model(%{}) == nil
  end

  test "workflow_profile chooses an Ouroboros stage model instead of blindly reusing the active model" do
    active = model(:codex, "codex")

    task_request = %{
      routing_decision: %{
        execution_route: :ouroboros_workflow,
        adapter_route: :interview
      }
    }

    profile = LoopBindingWorkflowDispatch.workflow_profile(task_request, %{active_model: active})

    assert profile.label == "interview/precision"
    assert profile.model_id in [:claude_api, :codex, :gemini]
  end

  test "workflow_model keeps direct/user-level routes on the active model" do
    active = model(:codex, "codex")

    task_request = %{
      routing_decision: %{
        execution_route: :ouroboros_workflow,
        adapter_route: :cancel
      }
    }

    assert LoopBindingWorkflowDispatch.workflow_profile(task_request, %{active_model: active}) ==
             nil

    assert LoopBindingWorkflowDispatch.workflow_model(task_request, %{active_model: active}) ==
             active
  end

  test "workflow_context includes only available carry-forward values" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          interview: %{session_id: "session-1", ambiguity: 0.12},
          workflow: %{
            latest_seed_path: "/tmp/seed.md",
            latest_seed_content: "seed_id: seed-1\n",
            latest_seed_id: "seed-1",
            latest_job_id: "job-1",
            latest_auto_session_id: "auto-1",
            latest_workflow_session_id: "workflow-session-1",
            latest_execution_id: "exec-1",
            latest_lineage_id: "lin-1"
          }
        }
      end)

    assert LoopBindingWorkflowDispatch.workflow_context(agent) == %{
             latest_interview_session_id: "session-1",
             latest_interview_ambiguity: 0.12,
             latest_seed_path: "/tmp/seed.md",
             latest_seed_content: "seed_id: seed-1\n",
             latest_job_id: "job-1",
             latest_auto_session_id: "auto-1",
             latest_workflow_session_id: "workflow-session-1",
             latest_execution_id: "exec-1",
             latest_lineage_id: "lin-1"
           }

    Agent.stop(agent)
  end

  test "project_dir prefers runtime project_dir and falls back to cwd" do
    assert LoopBindingWorkflowDispatch.project_dir(%{project_dir: "/tmp/ourocode"}) ==
             "/tmp/ourocode"

    assert LoopBindingWorkflowDispatch.project_dir(%{}) == File.cwd!()
    assert LoopBindingWorkflowDispatch.project_dir(nil) == File.cwd!()
  end

  test "handle_prompt dispatches UserLevel plugin routes through the guarded command runner" do
    parent = self()
    {:ok, agent} = LoopBindings.start_link()

    task_request = %TaskRequest{
      id: "user-level-dispatch",
      source: :dashboard,
      task_input: "ooo superpowers list",
      submitted_at_ms: System.system_time(:millisecond),
      routing_decision: %{
        kind: :user_level_plugin,
        execution_route: :user_level_plugin,
        runtime_source: :ouroboros,
        transport: :auto,
        requires_command_syntax?: false,
        advanced_shortcut?: true,
        reason: :user_level_plugin_resolved,
        plugin_id: "superpowers"
      }
    }

    runtime = %{
      project_dir: File.cwd!(),
      user_level_capabilities: [superpowers_capability()],
      user_level_external_command_runner: fn command, args, opts ->
        send(parent, {:user_level_runner, command, args, opts})
        {:ok, %{status: 0, stdout: "listed", stderr: ""}}
      end
    }

    assert :ok ==
             LoopBindingWorkflowDispatch.handle_prompt(
               agent,
               runtime,
               task_request,
               %{},
               %{
                 enqueue_failure: fn _agent, _parent_call_id, reason ->
                   send(parent, {:failure, reason})
                   :ok
                 end,
                 run_interview_session: fn _agent, _opts -> :ok end,
                 production_parent_call: fn _agent, _runtime, _parent_call_id ->
                   fn _payload -> :ok end
                 end,
                 mcp_url: fn -> "http://127.0.0.1:4000/mcp" end
               }
             )

    assert_receive {:user_level_runner, "ouroboros", ["superpowers", "list"],
                    %{cwd: cwd, workflow_run_id: "workflow-run:parent-user-level-dispatch"}},
                   1_000

    assert cwd == File.cwd!()
    refute_receive {:failure, _reason}, 100

    LoopBindings.stop(agent)
  end

  defp superpowers_capability do
    {:ok, capability} =
      Capability.new(%{
        plugin_id: "superpowers",
        source: :fixture,
        trust_scope: ["filesystem:read"],
        commands: [%{name: "list", risk_class: "read_only"}]
      })

    capability
  end

  defp model(id, label) do
    %Model{id: id, label: label, kind: :cli, status: :ready, run: fn _, _, _ -> :ok end}
  end
end
