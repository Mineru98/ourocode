defmodule Ourocode.Runtime.WorkflowHarness do
  @moduledoc """
  Minimal workflow-control harness.

  The harness gives Grok/gajae-style runs a single state-machine boundary
  without replacing existing MCP/Ouroboros execution paths yet.
  """

  alias Ourocode.Runtime.WorkflowRun

  @workflow_event_types MapSet.new([
                          :workflow_run_started,
                          :workflow_run_waiting,
                          :workflow_evidence_recorded,
                          :workflow_retry_scheduled,
                          :workflow_needs_user,
                          :workflow_run_completed,
                          :workflow_run_failed,
                          :workflow_run_cancelled
                        ])

  @spec run_started_event(String.t(), map(), keyword()) :: map()
  def run_started_event(parent_call_id, task_request, opts \\ []) do
    run = WorkflowRun.new(parent_call_id, task_request, opts)

    %{
      type: :workflow_run_started,
      event_type: :workflow_run_started,
      source: :workflow_harness,
      runtime_source: "ourocode",
      transport: :local,
      workflow_run_id: run.id,
      parent_call_id: parent_call_id,
      route: run.route,
      adapter_route: run.adapter_route,
      status: :dispatching,
      attempt: run.attempt,
      max_attempts: run.max_attempts,
      occurred_at_ms: run.created_at_ms
    }
    |> maybe_put(:task_id, Map.get(run, :task_id))
    |> maybe_put(:cwd, Map.get(run, :cwd))
  end

  @spec failure_event(String.t(), term(), keyword()) :: map()
  def failure_event(parent_call_id, reason, opts \\ []) do
    %{
      type: :workflow_run_failed,
      event_type: :workflow_run_failed,
      source: :workflow_harness,
      runtime_source: "ourocode",
      transport: :local,
      workflow_run_id: Keyword.get(opts, :run_id, "workflow-run:" <> parent_call_id),
      parent_call_id: parent_call_id,
      status: :failed,
      reason: inspect(reason),
      occurred_at_ms: Keyword.get(opts, :occurred_at_ms, System.system_time(:millisecond))
    }
  end

  @spec waiting_event(String.t(), String.t(), keyword()) :: map()
  def waiting_event(parent_call_id, current, opts \\ []) do
    lifecycle_event(:workflow_run_waiting, parent_call_id, :waiting, opts)
    |> maybe_put(:current, current)
  end

  @spec completed_event(String.t(), atom() | String.t(), keyword()) :: map()
  def completed_event(parent_call_id, reason \\ :completed, opts \\ []) do
    lifecycle_event(:workflow_run_completed, parent_call_id, :completed, opts)
    |> maybe_put(:reason, to_string(reason))
  end

  @spec evidence_event(String.t(), atom(), String.t(), keyword()) :: map()
  def evidence_event(parent_call_id, evidence_kind, summary, opts \\ []) do
    lifecycle_event(:workflow_evidence_recorded, parent_call_id, :waiting, opts)
    |> Map.merge(%{
      evidence_kind: evidence_kind,
      evidence_status: Keyword.get(opts, :evidence_status, :observed),
      summary: summary
    })
    |> maybe_put(:event_id, Keyword.get(opts, :event_id))
    |> maybe_put(:path, Keyword.get(opts, :path))
  end

  @spec apply_event(map(), map()) :: map()
  def apply_event(state, %{type: type} = event) when is_map(state) do
    if MapSet.member?(@workflow_event_types, type) do
      workflow = state |> Map.get(:workflow, %{}) |> apply_workflow_event(event)
      Map.put(state, :workflow, workflow)
    else
      state
    end
  end

  def apply_event(state, _event), do: state

  defp apply_workflow_event(workflow, %{type: :workflow_run_started} = event) do
    run =
      WorkflowRun.new(
        Map.fetch!(event, :parent_call_id),
        %{
          id: Map.get(event, :task_id),
          routing_decision: %{
            execution_route: Map.get(event, :route),
            adapter_route: Map.get(event, :adapter_route)
          }
        },
        run_id: Map.get(event, :workflow_run_id),
        status: :dispatching,
        attempt: Map.get(event, :attempt, 1),
        max_attempts: Map.get(event, :max_attempts, 1),
        cwd: Map.get(event, :cwd),
        occurred_at_ms: Map.get(event, :occurred_at_ms, System.system_time(:millisecond))
      )

    put_run(workflow, run)
  end

  defp apply_workflow_event(workflow, event) do
    case run_id(event) do
      nil ->
        workflow

      id ->
        runs = Map.get(workflow, :runs, %{})

        run =
          runs
          |> Map.get(id, %{id: id, parent_call_id: Map.get(event, :parent_call_id)})
          |> WorkflowRun.apply_event(event)

        workflow
        |> Map.put(:runs, Map.put(runs, id, run))
        |> Map.put(:latest_run_id, id)
    end
  end

  defp put_run(workflow, run) do
    workflow
    |> Map.update(:runs, %{run.id => run}, &Map.put(&1, run.id, run))
    |> Map.put(:latest_run_id, run.id)
  end

  defp lifecycle_event(type, parent_call_id, status, opts) do
    %{
      type: type,
      event_type: type,
      source: :workflow_harness,
      runtime_source: "ourocode",
      transport: :local,
      workflow_run_id: Keyword.get(opts, :run_id, "workflow-run:" <> parent_call_id),
      parent_call_id: parent_call_id,
      status: status,
      occurred_at_ms: Keyword.get(opts, :occurred_at_ms, System.system_time(:millisecond))
    }
  end

  defp run_id(event) do
    Map.get(event, :workflow_run_id) ||
      case Map.get(event, :parent_call_id) do
        parent_call_id when is_binary(parent_call_id) -> "workflow-run:" <> parent_call_id
        _other -> nil
      end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
