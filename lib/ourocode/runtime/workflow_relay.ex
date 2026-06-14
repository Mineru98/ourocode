defmodule Ourocode.Runtime.WorkflowRelay do
  @moduledoc """
  Runs non-interview Ouroboros workflow transport relays.
  """

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.StreamableHTTP

  alias Ourocode.Runtime.{
    ChildSessionPoller,
    LoopBindings,
    McpCapabilities,
    InterviewResponse,
    SeedArtifact,
    WorkflowHarness
  }

  alias Ourocode.Dashboard.ChildSessionPanes

  @relay_grace_ms 2_000
  @transport_timeout_ms 30_000
  # Transport timeout plus margin: if the worker neither replies nor dies
  # within this window, the relay gives up instead of blocking forever.
  @relay_timeout_ms 35_000

  @spec run(pid(), map(), String.t(), map(), Path.t(), String.t(), keyword()) :: :ok
  def run(agent, runtime, parent_call_id, payload, project_dir, mcp_url, opts \\ []) do
    relay = self()
    workflow_run_id = Keyword.get(opts, :workflow_run_id, "workflow-run:" <> parent_call_id)

    execute_parent_call =
      Keyword.get(opts, :execute_parent_call, &StreamableHTTP.execute_parent_call/2)

    call_ref = make_ref()

    worker =
      spawn(fn ->
        result =
          execute_parent_call.(
            [
              url: mcp_url,
              parent_call_id: parent_call_id,
              runtime_source: "ouroboros",
              subscriber: relay,
              mcp_session: true,
              timeout: @transport_timeout_ms
            ],
            payload
          )

        send(relay, {:relay_worker_done, call_ref, result})
      end)

    monitor_ref = Process.monitor(worker)

    drain(agent, runtime, %{
      parent_call_id: parent_call_id,
      project_dir: project_dir,
      workflow_run_id: workflow_run_id,
      worker: worker,
      monitor_ref: monitor_ref,
      call_ref: call_ref,
      timeout_ms: Keyword.get(opts, :timeout, @relay_timeout_ms),
      flush: Keyword.get(opts, :flush, &__MODULE__.flush/1),
      capture_opts: Keyword.take(opts, [:poller_starter]) ++ [mcp_url: mcp_url]
    })
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

  defp drain(agent, runtime, ctx) do
    %{
      parent_call_id: parent_call_id,
      workflow_run_id: workflow_run_id,
      worker: worker,
      monitor_ref: monitor_ref,
      call_ref: call_ref
    } = ctx

    receive do
      {:ourocode_event, event} ->
        LoopBindings.enqueue(agent, event)
        McpCapabilities.maybe_ingest(runtime, event)
        drain(agent, runtime, ctx)

      {:relay_worker_done, ^call_ref, {:error, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        relay_failure(agent, ctx, {:transport_failed, reason})

      {:relay_worker_done, ^call_ref, {:ok, result}} ->
        Process.demonitor(monitor_ref, [:flush])

        case capture_workflow_result(agent, result, ctx.project_dir, ctx.capture_opts) do
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

        ctx.flush.(agent)

      {:relay_worker_done, ^call_ref, _other} ->
        Process.demonitor(monitor_ref, [:flush])

        LoopBindings.enqueue(
          agent,
          WorkflowHarness.completed_event(parent_call_id, :relay_done_unknown,
            run_id: workflow_run_id
          )
        )

        ctx.flush.(agent)

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        relay_failure(agent, ctx, {:relay_worker_exit, reason})
    after
      ctx.timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(worker, :kill)
        drop_late_worker_done(call_ref)
        relay_failure(agent, ctx, {:relay_worker_timeout, ctx.timeout_ms})
    end
  end

  defp relay_failure(agent, ctx, reason) do
    LoopBindings.enqueue(agent, failure_event(ctx.parent_call_id, reason))

    LoopBindings.enqueue(
      agent,
      WorkflowHarness.failure_event(ctx.parent_call_id, reason, run_id: ctx.workflow_run_id)
    )

    ctx.flush.(agent)
  end

  defp drop_late_worker_done(call_ref) do
    receive do
      {:relay_worker_done, ^call_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  @doc false
  @spec capture_workflow_result(pid(), term(), Path.t(), keyword()) :: :ok | {:ok, map()}
  def capture_workflow_result(agent, result, project_dir, opts \\ [])

  def capture_workflow_result(agent, %ParentCallResult{} = result, project_dir, opts)
      when is_pid(agent) do
    response = result.response

    response
    |> workflow_handles(result.external_ids)
    |> tap(&register_workflow_child_pane(agent, result, &1, opts))
    |> capture_workflow_handles(agent)

    result.response
    |> InterviewResponse.text()
    |> capture_seed_artifact(agent, project_dir, InterviewResponse.meta(result.response))
  end

  def capture_workflow_result(_agent, _result, _project_dir, _opts), do: :ok

  defp capture_seed_artifact(text, agent, cwd, meta) when is_binary(text) and is_map(meta) do
    case SeedArtifact.capture(text, cwd, meta) do
      {:ok, %{path: path, seed_id: seed_id}} ->
        Agent.update(agent, fn state ->
          workflow =
            state
            |> Map.get(:workflow, %{})
            |> Map.put(:latest_seed_path, path)
            |> Map.put(:latest_seed_id, seed_id)
            |> Map.put(:latest_seed_content, File.read!(path))

          %{state | workflow: workflow}
        end)

        {:ok, %{path: path, seed_id: seed_id}}

      _ignore_or_error ->
        :ok
    end
  end

  defp capture_seed_artifact(_text, _agent, _cwd, _meta), do: :ok

  defp capture_workflow_handles(handles, _agent) when handles == %{}, do: :ok

  defp capture_workflow_handles(handles, agent) do
    Agent.update(agent, fn state ->
      workflow =
        state
        |> Map.get(:workflow, %{})
        |> Map.merge(handles)

      %{state | workflow: workflow}
    end)
  end

  defp register_workflow_child_pane(_agent, _result, handles, _opts) when handles == %{},
    do: :ok

  defp register_workflow_child_pane(agent, %ParentCallResult{} = result, handles, opts)
       when is_pid(agent) and is_map(handles) do
    child_id = workflow_child_id(handles)

    if is_binary(child_id) and child_id != "" do
      safe_enqueue_runtime_event(
        agent,
        workflow_child_registered_event(result, handles, child_id)
      )

      Agent.update(agent, fn state ->
        child_state = Map.get(state, :child, ChildSessionPanes.new())

        case ChildSessionPanes.register_child_pane(child_state, %{
               child_id: child_id,
               parent_call_id: result.parent_call_id,
               runtime_source: "ouroboros",
               transport: :streamable_http,
               external_ids: workflow_external_ids(handles),
               stream_cursor: %{
                 transport: :streamable_http,
                 child_id: child_id,
                 parent_call_id: result.parent_call_id
               },
               pane_state: %{
                 title: workflow_child_title(handles),
                 stream_entries: [workflow_start_entry(result, handles)]
               }
             }) do
          {:ok, child_state} -> Map.put(state, :child, child_state)
          {:error, _reason} -> state
        end
      end)

      maybe_start_child_poller(agent, result, handles, opts)
    end

    :ok
  end

  # Background `start_*` tools return immediately while the job keeps working
  # server-side. Poll `ouroboros_job_status` so the registered child pane keeps
  # receiving progress instead of going blind after the call returns. Only
  # job-backed children are pollable, and only when the relay knows its MCP
  # url (direct `capture_workflow_result/3` callers skip polling).
  defp maybe_start_child_poller(agent, %ParentCallResult{} = result, handles, opts) do
    job_id = Map.get(handles, :latest_job_id)
    mcp_url = Keyword.get(opts, :mcp_url)

    if is_binary(job_id) and job_id != "" and is_binary(mcp_url) and mcp_url != "" do
      poller_starter = Keyword.get(opts, :poller_starter, &ChildSessionPoller.start/2)

      poller_starter.(agent,
        child_id: job_id,
        job_id: job_id,
        parent_call_id: result.parent_call_id,
        mcp_url: mcp_url
      )
    end

    :ok
  end

  defp safe_enqueue_runtime_event(agent, event) do
    if Agent.get(agent, &Map.has_key?(&1, :inbox)) do
      LoopBindings.enqueue(agent, event)
    end

    :ok
  end

  defp workflow_child_registered_event(%ParentCallResult{} = result, handles, child_id) do
    external_ids = workflow_external_ids(handles)
    title = workflow_child_title(handles)

    %{
      type: :child_session_registered,
      event_type: :child_session_registered,
      source: :terminal_runtime,
      runtime_source: "ouroboros",
      transport: :streamable_http,
      pane_id: ChildSessionPanes.child_pane_id(child_id),
      child_id: child_id,
      session_id: child_id,
      parent_call_id: result.parent_call_id,
      external_ids: external_ids,
      title: title,
      task: title,
      line: workflow_entry_content(result.response),
      status: "running",
      pane_state: %{
        title: title,
        stream_entries: [workflow_start_entry(result, handles)]
      },
      occurred_at_ms: System.system_time(:millisecond),
      payload: %{
        child_id: child_id,
        parent_call_id: result.parent_call_id,
        external_ids: external_ids
      }
    }
  end

  defp workflow_child_id(handles) do
    Map.get(handles, :latest_job_id) ||
      Map.get(handles, :latest_auto_session_id) ||
      Map.get(handles, :latest_execution_id) ||
      Map.get(handles, :latest_lineage_id) ||
      Map.get(handles, :latest_workflow_session_id)
  end

  defp workflow_external_ids(handles) do
    %{}
    |> maybe_put_external_id("job_id", Map.get(handles, :latest_job_id))
    |> maybe_put_external_id("auto_session_id", Map.get(handles, :latest_auto_session_id))
    |> maybe_put_external_id("session_id", Map.get(handles, :latest_workflow_session_id))
    |> maybe_put_external_id("execution_id", Map.get(handles, :latest_execution_id))
    |> maybe_put_external_id("lineage_id", Map.get(handles, :latest_lineage_id))
  end

  defp maybe_put_external_id(map, _key, nil), do: map
  defp maybe_put_external_id(map, key, value), do: Map.put(map, key, value)

  defp workflow_child_title(%{latest_job_id: job_id}) when is_binary(job_id),
    do: "Ouroboros job " <> job_id

  defp workflow_child_title(%{latest_auto_session_id: auto_session_id})
       when is_binary(auto_session_id),
       do: "Ouroboros auto " <> auto_session_id

  defp workflow_child_title(%{latest_execution_id: execution_id}) when is_binary(execution_id),
    do: "Ouroboros execution " <> execution_id

  defp workflow_child_title(_handles), do: "Ouroboros workflow"

  defp workflow_start_entry(%ParentCallResult{} = result, handles) do
    %{
      type: :workflow_background_session_attached,
      parent_call_id: result.parent_call_id,
      content: workflow_entry_content(result.response),
      external_ids: workflow_external_ids(handles),
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  defp workflow_entry_content(response) do
    response
    |> InterviewResponse.text()
    |> case do
      text when is_binary(text) and text != "" -> text
      _empty -> "Background Ouroboros session attached"
    end
  end

  defp workflow_handles(response, external_ids) do
    response
    |> collect_handle_sources(external_ids)
    |> Enum.reduce(%{}, fn source, acc ->
      acc
      |> put_handle(:latest_job_id, source, ["job_id", :job_id])
      |> put_handle(:latest_auto_session_id, source, [
        "auto_session_id",
        :auto_session_id,
        "autoSessionId",
        :autoSessionId
      ])
      |> put_handle(:latest_execution_id, source, ["execution_id", :execution_id])
      |> put_handle(:latest_lineage_id, source, ["lineage_id", :lineage_id])
      |> put_handle(:latest_workflow_session_id, source, ["session_id", :session_id])
    end)
  end

  defp collect_handle_sources(response, external_ids) do
    result = if is_map(response["result"]), do: response["result"], else: %{}

    [
      external_ids,
      response,
      result,
      result["meta"],
      result["_meta"],
      result["structuredContent"],
      result["structured_content"],
      nested_meta(result["structuredContent"]),
      nested_meta(result["structured_content"])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp nested_meta(%{"meta" => meta}) when is_map(meta), do: meta
  defp nested_meta(%{"_meta" => meta}) when is_map(meta), do: meta
  defp nested_meta(_value), do: %{}

  defp put_handle(acc, target_key, source, source_keys) do
    case first_string_value(source, source_keys) do
      nil -> acc
      value -> Map.put_new(acc, target_key, value)
    end
  end

  defp first_string_value(source, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(source, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

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
