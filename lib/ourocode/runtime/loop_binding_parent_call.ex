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

    fn payload ->
      relay = self()

      spawn(fn ->
        result =
          execute_parent_call.(
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

      drain_until_done(agent, runtime, flush)
    end
  end

  defp drain_until_done(agent, runtime, flush) do
    receive do
      {:ourocode_event, event} ->
        LoopBindingEventFlow.enqueue(agent, event)
        McpCapabilities.maybe_ingest(runtime, event)
        drain_until_done(agent, runtime, flush)

      {:relay_worker_done, result} ->
        flush.(agent)
        result
    end
  end
end
