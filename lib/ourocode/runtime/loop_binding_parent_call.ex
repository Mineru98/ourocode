defmodule Ourocode.Runtime.LoopBindingParentCall do
  @moduledoc """
  Production parent MCP call relay for interview loop bindings.
  """

  alias Ourocode.MCP.Transport.StreamableHTTP

  alias Ourocode.Runtime.{
    LoopBindingEventFlow,
    McpCapabilities,
    WorkflowRelay
  }

  @spec build(pid(), map(), String.t(), String.t(), keyword()) :: (map() -> term())
  def build(agent, runtime, parent_call_id, mcp_url, opts \\ []) do
    execute_parent_call =
      Keyword.get(opts, :execute_parent_call, &StreamableHTTP.execute_parent_call/2)

    flush = Keyword.get(opts, :flush, &WorkflowRelay.flush/1)
    timeout_ms = Keyword.get(opts, :timeout, 30_000)

    fn payload ->
      relay = self()
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
                timeout: timeout_ms
              ],
              payload
            )

          send(relay, {:relay_worker_done, call_ref, result})
        end)

      monitor_ref = Process.monitor(worker)

      drain_until_done(agent, runtime, flush, worker, monitor_ref, call_ref, timeout_ms)
    end
  end

  defp drain_until_done(agent, runtime, flush, worker, monitor_ref, call_ref, timeout_ms) do
    receive do
      {:ourocode_event, event} ->
        LoopBindingEventFlow.enqueue(agent, event)
        McpCapabilities.maybe_ingest(runtime, event)
        drain_until_done(agent, runtime, flush, worker, monitor_ref, call_ref, timeout_ms)

      {:relay_worker_done, ^call_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        flush.(agent)
        result

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        flush.(agent)
        {:error, {:parent_call_worker_exit, reason}}
    after
      timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(worker, :kill)
        drop_late_worker_done(call_ref)
        flush.(agent)
        {:error, {:parent_call_timeout, timeout_ms}}
    end
  end

  defp drop_late_worker_done(call_ref) do
    receive do
      {:relay_worker_done, ^call_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
