defmodule Ourocode.Runtime.WorkflowRelay do
  @moduledoc """
  Runs non-interview Ouroboros workflow transport relays.
  """

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.StreamableHTTP

  alias Ourocode.Runtime.{
    LoopBindings,
    McpCapabilities,
    InterviewResponse,
    SeedArtifact,
    WorkflowHarness
  }

  @relay_grace_ms 2_000

  @spec run(pid(), map(), String.t(), map(), Path.t(), String.t(), keyword()) :: :ok
  def run(agent, runtime, parent_call_id, payload, project_dir, mcp_url, opts \\ []) do
    relay = self()
    workflow_run_id = Keyword.get(opts, :workflow_run_id, "workflow-run:" <> parent_call_id)

    spawn(fn ->
      result =
        StreamableHTTP.execute_parent_call(
          [
            url: mcp_url,
            parent_call_id: parent_call_id,
            runtime_source: "ouroboros",
            subscriber: relay,
            mcp_session: true,
            timeout: 30_000
          ],
          payload
        )

      send(relay, {:relay_worker_done, result})
    end)

    drain(agent, runtime, parent_call_id, project_dir, workflow_run_id)
  end

  @spec flush(pid()) :: :ok
  def flush(agent) do
    receive do
      {:ourocode_event, event} ->
        LoopBindings.enqueue(agent, event)
        flush(agent)
    after
      @relay_grace_ms -> :ok
    end
  end

  defp drain(agent, runtime, parent_call_id, project_dir, workflow_run_id) do
    receive do
      {:ourocode_event, event} ->
        LoopBindings.enqueue(agent, event)
        McpCapabilities.maybe_ingest(runtime, event)
        drain(agent, runtime, parent_call_id, project_dir, workflow_run_id)

      {:relay_worker_done, {:error, reason}} ->
        LoopBindings.enqueue(agent, failure_event(parent_call_id, {:transport_failed, reason}))

        LoopBindings.enqueue(
          agent,
          WorkflowHarness.failure_event(parent_call_id, {:transport_failed, reason},
            run_id: workflow_run_id
          )
        )

        flush(agent)

      {:relay_worker_done, {:ok, result}} ->
        case maybe_capture_seed_artifact(agent, result, project_dir) do
          {:ok, %{path: path, seed_id: seed_id}} ->
            LoopBindings.enqueue(
              agent,
              WorkflowHarness.evidence_event(
                parent_call_id,
                :seed_artifact,
                "seed artifact captured",
                run_id: workflow_run_id,
                event_id: seed_id,
                path: path
              )
            )

          _other ->
            :ok
        end

        LoopBindings.enqueue(
          agent,
          WorkflowHarness.completed_event(parent_call_id, :relay_completed,
            run_id: workflow_run_id
          )
        )

        flush(agent)

      {:relay_worker_done, _other} ->
        LoopBindings.enqueue(
          agent,
          WorkflowHarness.completed_event(parent_call_id, :relay_done_unknown,
            run_id: workflow_run_id
          )
        )

        flush(agent)
    end
  end

  defp maybe_capture_seed_artifact(agent, %ParentCallResult{} = result, project_dir) do
    result.response
    |> InterviewResponse.text()
    |> capture_seed_artifact(agent, project_dir, InterviewResponse.meta(result.response))
  end

  defp maybe_capture_seed_artifact(_agent, _result, _project_dir), do: :ok

  defp capture_seed_artifact(text, agent, cwd, meta) when is_binary(text) and is_map(meta) do
    case SeedArtifact.capture(text, cwd, meta) do
      {:ok, %{path: path, seed_id: seed_id}} ->
        Agent.update(agent, fn state ->
          workflow =
            state
            |> Map.get(:workflow, %{})
            |> Map.put(:latest_seed_path, path)
            |> Map.put(:latest_seed_id, seed_id)

          %{state | workflow: workflow}
        end)

        {:ok, %{path: path, seed_id: seed_id}}

      _ignore_or_error ->
        :ok
    end
  end

  defp capture_seed_artifact(_text, _agent, _cwd, _meta), do: :ok

  defp failure_event(parent_call_id, reason) do
    %{
      type: :parent_call_failed,
      event_type: :parent_call_failed,
      source: :terminal_runtime,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{status: :failed, reason: inspect(reason)}
    }
  end
end
