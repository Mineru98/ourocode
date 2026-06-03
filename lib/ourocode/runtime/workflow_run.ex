defmodule Ourocode.Runtime.WorkflowRun do
  @moduledoc """
  Small workflow-control record shared by TUI, ACP, and runtime dispatch.
  """

  @type status ::
          :queued
          | :dispatching
          | :waiting
          | :retrying
          | :needs_user
          | :completed
          | :failed
          | :cancelled

  @type t :: %{
          required(:id) => String.t(),
          required(:status) => status(),
          required(:parent_call_id) => String.t(),
          required(:route) => atom() | nil,
          required(:adapter_route) => atom() | nil,
          required(:attempt) => pos_integer(),
          required(:max_attempts) => pos_integer(),
          required(:evidence) => [map()],
          required(:created_at_ms) => integer(),
          required(:updated_at_ms) => integer()
        }

  @spec new(String.t(), map(), keyword()) :: t()
  def new(parent_call_id, task_request, opts \\ [])
      when is_binary(parent_call_id) and is_map(task_request) do
    now = Keyword.get(opts, :occurred_at_ms, System.system_time(:millisecond))
    routing = Map.get(task_request, :routing_decision, %{})

    %{
      id: Keyword.get(opts, :run_id, "workflow-run:" <> parent_call_id),
      status: Keyword.get(opts, :status, :queued),
      parent_call_id: parent_call_id,
      task_id: task_id(task_request),
      route: Map.get(routing, :execution_route),
      adapter_route: Map.get(routing, :adapter_route),
      source: Map.get(task_request, :source),
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: Keyword.get(opts, :max_attempts, 1),
      evidence: [],
      created_at_ms: now,
      updated_at_ms: now
    }
    |> maybe_put(:cwd, Keyword.get(opts, :cwd))
  end

  @spec apply_event(t() | map() | nil, map()) :: t() | map()
  def apply_event(run, event) when is_map(run) and is_map(event) do
    status = status_for(Map.get(event, :type), Map.get(event, :status))

    run
    |> maybe_put(:status, status)
    |> maybe_put(:current, Map.get(event, :current))
    |> maybe_put(:reason, Map.get(event, :reason))
    |> maybe_put(:updated_at_ms, Map.get(event, :occurred_at_ms))
    |> maybe_append_evidence(event)
  end

  def apply_event(run, _event), do: run

  defp status_for(:workflow_run_started, _status), do: :dispatching
  defp status_for(:workflow_run_waiting, _status), do: :waiting
  defp status_for(:workflow_retry_scheduled, _status), do: :retrying
  defp status_for(:workflow_needs_user, _status), do: :needs_user
  defp status_for(:workflow_run_completed, _status), do: :completed
  defp status_for(:workflow_run_failed, _status), do: :failed
  defp status_for(:workflow_run_cancelled, _status), do: :cancelled
  defp status_for(_type, status) when is_atom(status), do: status
  defp status_for(_type, _status), do: nil

  defp maybe_append_evidence(run, %{type: :workflow_evidence_recorded} = event) do
    evidence =
      %{
        kind: Map.get(event, :evidence_kind, :runtime_event),
        source: Map.get(event, :source, :runtime),
        status: Map.get(event, :evidence_status, :observed),
        summary: Map.get(event, :summary),
        event_id: Map.get(event, :event_id)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Map.update(run, :evidence, [evidence], &[evidence | &1])
  end

  defp maybe_append_evidence(run, _event), do: run

  defp task_id(%{id: id}), do: to_string(id)
  defp task_id(%{"id" => id}), do: to_string(id)
  defp task_id(_task_request), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
