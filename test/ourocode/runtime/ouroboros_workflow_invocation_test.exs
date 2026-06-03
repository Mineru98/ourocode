defmodule Ourocode.Runtime.OuroborosWorkflowInvocationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosWorkflowInvocation
  alias Ourocode.TaskRequest

  test "builds auto payload from goal and CLI-style flags" do
    task =
      parse!(
        "ooo auto improve startup --skip-run --complete-product --max-interview-rounds 7 --max-repair-rounds 3 --pipeline-timeout-seconds 90",
        id: "auto-task"
      )

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{cwd: "/tmp/project", request_id: "req-auto"},
               :auto
             )

    assert payload["id"] == "req-auto"
    assert payload["params"]["name"] == "ouroboros_start_auto"

    assert payload["params"]["arguments"] == %{
             "goal" => "improve startup",
             "cwd" => "/tmp/project",
             "skip_run" => true,
             "complete_product" => true,
             "max_interview_rounds" => 7,
             "max_repair_rounds" => 3,
             "pipeline_timeout_seconds" => 90.0
           }
  end

  test "builds auto resume payload and rejects timeout override on resume" do
    task = parse!("ooo auto --resume auto_123 --skip-run", id: "auto-resume-task")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{cwd: "/tmp/project"},
               :auto
             )

    assert payload["params"]["arguments"] == %{
             "resume" => "auto_123",
             "cwd" => "/tmp/project",
             "skip_run" => true
           }

    assert {:error, :auto_resume_rejects_pipeline_timeout_seconds} =
             "ooo auto --resume auto_123 --pipeline-timeout-seconds 90"
             |> parse!(id: "auto-bad-resume")
             |> OuroborosWorkflowInvocation.build_request_payload(%{}, :auto)
  end

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

  test "builds Ralph payload from explicit lineage id" do
    task = parse!("ooo ralph --lineage-id lin_123 --no-execute --serial --max-generations 4")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{cwd: "/tmp/project"},
               :ralph
             )

    assert payload["params"]["name"] == "ouroboros_ralph"

    assert payload["params"]["arguments"] == %{
             "lineage_id" => "lin_123",
             "project_dir" => "/tmp/project",
             "execute" => false,
             "parallel" => false,
             "max_generations" => 4
           }
  end

  test "builds Ralph payload from latest validated seed content" do
    task = parse!("ooo ralph --max-generations 2", id: "ralph-task")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               task,
               %{cwd: "/tmp/project", latest_seed_content: "seed_id: seed-1\n"},
               :ralph
             )

    assert payload["params"]["arguments"]["lineage_id"] == "ralph-ralph-task"
    assert payload["params"]["arguments"]["seed_content"] == "seed_id: seed-1\n"
    assert payload["params"]["arguments"]["max_generations"] == 2
  end

  test "builds evolve status, rewind, and step payloads" do
    status = parse!("ooo evolve --status lin_123")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(status, %{}, :evolve)

    assert payload["params"]["name"] == "ouroboros_lineage_status"
    assert payload["params"]["arguments"] == %{"lineage_id" => "lin_123"}

    rewind = parse!("ooo evolve --rewind lin_123 2")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(rewind, %{}, :evolve)

    assert payload["params"]["name"] == "ouroboros_evolve_rewind"
    assert payload["params"]["arguments"] == %{"lineage_id" => "lin_123", "to_generation" => 2}

    step = parse!("ooo evolve --lineage-id lin_123 --no-execute")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               step,
               %{cwd: "/tmp/project"},
               :evolve
             )

    assert payload["params"]["name"] == "ouroboros_evolve_step"
    assert payload["params"]["arguments"]["lineage_id"] == "lin_123"
    assert payload["params"]["arguments"]["execute"] == false
  end

  test "builds status and evaluate payloads from carried workflow context" do
    status = parse!("ooo status")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               status,
               %{latest_workflow_session_id: "sess-1"},
               :status
             )

    assert payload["params"]["name"] == "ouroboros_session_status"
    assert payload["params"]["arguments"] == %{"session_id" => "sess-1"}

    evaluate = parse!("ooo evaluate --consensus type docs")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               evaluate,
               %{
                 latest_execution_id: "exec-1",
                 latest_evaluation_artifact: "# Result\n",
                 latest_seed_content: "seed_id: seed-1\n"
               },
               :evaluate
             )

    assert payload["params"]["name"] == "ouroboros_evaluate"
    assert payload["params"]["arguments"]["session_id"] == "exec-1"
    assert payload["params"]["arguments"]["artifact"] == "# Result\n"
    assert payload["params"]["arguments"]["artifact_type"] == "docs"
    assert payload["params"]["arguments"]["seed_content"] == "seed_id: seed-1\n"
    assert payload["params"]["arguments"]["trigger_consensus"] == true
  end

  test "builds QA, lateral, and brownfield payloads" do
    qa = parse!("ooo qa bar must satisfy the spec")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(
               qa,
               %{latest_evaluation_artifact: "artifact body"},
               :qa
             )

    assert payload["params"]["name"] == "ouroboros_qa"
    assert payload["params"]["arguments"]["artifact"] == "artifact body"
    assert payload["params"]["arguments"]["quality_bar"] == "must satisfy the spec"
    assert payload["params"]["arguments"]["artifact_type"] == "custom"

    lateral = parse!("ooo lateral hacker simplify the workflow routing")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(lateral, %{}, :lateral)

    assert payload["params"]["name"] == "ouroboros_lateral_think"
    assert payload["params"]["arguments"]["persona"] == "hacker"
    assert payload["params"]["arguments"]["problem_context"] == "simplify the workflow routing"
    assert payload["params"]["arguments"]["current_approach"] == "none yet - first attempt"

    brownfield = parse!("ooo brownfield set 6,18,19")

    assert {:ok, payload} =
             OuroborosWorkflowInvocation.build_request_payload(brownfield, %{}, :brownfield)

    assert payload["params"]["name"] == "ouroboros_brownfield"
    assert payload["params"]["arguments"] == %{"action" => "set_default", "indices" => "6,18,19"}
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

    assert {:error, :missing_ralph_lineage_or_seed} =
             OuroborosWorkflowInvocation.build_request_payload(
               parse!("ooo ralph fix it"),
               %{},
               :ralph
             )

    assert {:error, :missing_evolve_lineage_or_seed} =
             OuroborosWorkflowInvocation.build_request_payload(
               parse!("ooo evolve fix it"),
               %{},
               :evolve
             )

    assert {:error, :missing_execution_session_id} =
             OuroborosWorkflowInvocation.build_request_payload(parse!("ooo status"), %{}, :status)

    assert {:error, :missing_evaluation_artifact} =
             OuroborosWorkflowInvocation.build_request_payload(
               parse!("ooo evaluate session sess-1"),
               %{},
               :evaluate
             )

    assert {:error, :missing_qa_artifact} =
             OuroborosWorkflowInvocation.build_request_payload(parse!("ooo qa"), %{}, :qa)

    assert {:error, :missing_lateral_context} =
             OuroborosWorkflowInvocation.build_request_payload(
               parse!("ooo lateral"),
               %{},
               :lateral
             )
  end

  defp parse!(input, opts \\ []) do
    {:ok, task} = TaskRequest.parse(input, opts)
    task
  end
end
