defmodule Ourocode.Runtime.LoopBindingWorkflowDispatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Runtime.LoopBindingWorkflowDispatch

  test "ouroboros_route? detects workflow-routed task requests only" do
    assert LoopBindingWorkflowDispatch.ouroboros_route?(%{
             routing_decision: %{execution_route: :ouroboros_workflow}
           })

    refute LoopBindingWorkflowDispatch.ouroboros_route?(%{
             routing_decision: %{execution_route: :runtime}
           })

    refute LoopBindingWorkflowDispatch.ouroboros_route?(%{})
  end

  test "interview_task? detects interview adapter route only" do
    assert LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :interview}
           })

    refute LoopBindingWorkflowDispatch.interview_task?(%{
             routing_decision: %{adapter_route: :run}
           })
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
end
