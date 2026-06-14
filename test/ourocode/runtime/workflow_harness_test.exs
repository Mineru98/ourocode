defmodule Ourocode.Runtime.WorkflowHarnessTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.WorkflowHarness

  test "starts and fails workflow runs from lifecycle events" do
    task = %{
      id: "task-1",
      routing_decision: %{execution_route: :ouroboros_workflow, adapter_route: :interview}
    }

    started =
      WorkflowHarness.run_started_event("parent-task-1", task,
        occurred_at_ms: 10,
        model_profile: %{label: "interview/precision", model_label: "claude"}
      )

    state = WorkflowHarness.apply_event(%{workflow: %{}}, started)

    assert %{
             status: :dispatching,
             parent_call_id: "parent-task-1",
             route: :ouroboros_workflow,
             adapter_route: :interview,
             model_profile: %{label: "interview/precision", model_label: "claude"}
           } = state.workflow.runs["workflow-run:parent-task-1"]

    failed = WorkflowHarness.failure_event("parent-task-1", :boom, occurred_at_ms: 20)
    state = WorkflowHarness.apply_event(state, failed)

    assert %{status: :failed, reason: ":boom"} =
             state.workflow.runs["workflow-run:parent-task-1"]
  end

  test "records evidence and completion for workflow runs" do
    started =
      WorkflowHarness.run_started_event(
        "parent-task-2",
        %{id: "task-2", routing_decision: %{execution_route: :ouroboros_workflow}},
        occurred_at_ms: 10
      )

    evidence =
      WorkflowHarness.evidence_event(
        "parent-task-2",
        :seed_artifact,
        "seed artifact captured",
        event_id: "seed-1",
        path: "/tmp/seed.yml",
        occurred_at_ms: 20
      )

    completed =
      WorkflowHarness.completed_event("parent-task-2", :relay_completed, occurred_at_ms: 30)

    state =
      %{workflow: %{}}
      |> WorkflowHarness.apply_event(started)
      |> WorkflowHarness.apply_event(evidence)
      |> WorkflowHarness.apply_event(completed)

    assert %{
             status: :completed,
             evidence: [%{kind: :seed_artifact, summary: "seed artifact captured"}]
           } = state.workflow.runs["workflow-run:parent-task-2"]
  end
end
