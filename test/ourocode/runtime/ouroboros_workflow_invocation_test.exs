defmodule Ourocode.Runtime.OuroborosWorkflowInvocationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosWorkflowInvocation
  alias Ourocode.TaskRequest

  test "builds generate-seed payload from the latest interview session" do
    task = parse!("ooo seed", id: "seed-task")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{
                 latest_interview_session_id: "interview_123",
                 latest_interview_ambiguity: 0.12,
                 request_id: "req-seed"
               },
               :seed
             )

    assert payload["id"] == "req-seed"
    assert payload["method"] == "tools/call"
    assert payload["params"]["name"] == "ouroboros_generate_seed"
    assert payload["params"]["arguments"]["session_id"] == "interview_123"
    assert payload["params"]["arguments"]["ambiguity_score"] == 0.12

    assert payload["params"]["arguments"]["client_gates"] == [
             "seed_ready_acceptance_guard",
             "restate_goal_approved"
           ]
  end

  test "builds run payload from an explicit seed path" do
    task = parse!("ooo run seed_abc123.yaml --no-qa", id: "run-task")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{cwd: "/tmp/project"},
               :run
             )

    assert payload["params"]["name"] == "ouroboros_start_execute_seed"
    assert payload["params"]["arguments"]["seed_path"] == "seed_abc123.yaml"
    assert payload["params"]["arguments"]["cwd"] == "/tmp/project"
    assert payload["params"]["arguments"]["skip_qa"] == true
    assert payload["params"]["arguments"]["idempotency_key"] == "ourocode-run-run-task"
  end

  test "builds run payload from the latest generated seed path" do
    task = parse!("ooo run", id: "run-latest")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{latest_seed_path: "/tmp/project/seed_latest.yaml"},
               :run
             )

    assert payload["params"]["arguments"]["seed_path"] == "/tmp/project/seed_latest.yaml"
  end

  test "requires an interview session for seed and a seed path for run" do
    assert {:error, :missing_interview_session_id} =
             OuroborosWorkflowInvocation.build_request_payload(parse!("ooo seed"), %{}, :seed)

    assert {:error, :missing_seed_path} =
             OuroborosWorkflowInvocation.build_request_payload(
               parse!("ooo run"),
               %{seed_search_dirs: [System.tmp_dir!()]},
               :run
             )
  end

  defp parse!(input, opts \\ []) do
    {:ok, task} = TaskRequest.parse(input, opts)
    task
  end
end
