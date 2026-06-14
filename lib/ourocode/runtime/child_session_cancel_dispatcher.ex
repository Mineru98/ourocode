defmodule Ourocode.Runtime.ChildSessionCancelDispatcher do
  @moduledoc """
  Production dispatcher for the builtin `/interrupt` and `/cancel` child
  actions.

  `Ourocode.Runtime.ChildSessionActionDispatch` resolves the focused child
  pane and hands delivery to a configured dispatcher function. Without one it
  returns `:*_dispatcher_not_configured`, so the slash commands could never
  actually stop server-side work. This module builds that dispatcher: it maps
  the focused pane's `external_ids` onto the cancellation tools the live
  Ouroboros MCP server exposes and issues a `tools/call`:

    * `"job_id"` present       -> `ouroboros_cancel_job` (`job_id` argument)
    * `"execution_id"` present -> `ouroboros_cancel_execution`
      (`execution_id` argument, optional `reason`)

  The server exposes no separate interrupt tool, so both the interrupt and
  cancel actions deliver through the same cancellation tools; the user-facing
  distinction (reason text) is preserved in the `ouroboros_cancel_execution`
  `reason` argument. Panes without a job or execution handle are reported as
  `{:child_pane_not_cancellable, pane_id}`.

  The transport call is injectable for tests via `:cancel_caller` (defaults to
  `StreamableHTTP.execute_parent_call/2`), mirroring the
  `ChildSessionPoller` `:status_caller` seam, so no test performs a real
  network call.
  """

  alias Ourocode.MCP.Transport.StreamableHTTP

  @cancel_timeout_ms 15_000

  @type dispatcher ::
          (map(), String.t(), map() -> {:ok, map()} | {:error, term()})

  @doc """
  Builds the 3-arity dispatcher fun consumed by
  `ChildSessionActionDispatch.deliver_request/6`.

  Required opts: `:mcp_url`. Injectable: `:cancel_caller` (defaults to
  `StreamableHTTP.execute_parent_call/2`).
  """
  @spec build(keyword()) :: dispatcher()
  def build(opts) when is_list(opts) do
    mcp_url = Keyword.fetch!(opts, :mcp_url)
    cancel_caller = Keyword.get(opts, :cancel_caller, &StreamableHTTP.execute_parent_call/2)

    fn pane, _serialized_request, delivery_context ->
      dispatch(pane, delivery_context, cancel_caller, mcp_url)
    end
  end

  defp dispatch(pane, delivery_context, cancel_caller, mcp_url) do
    case cancel_tool_call(pane, delivery_context) do
      {:ok, tool, arguments, request_id} ->
        execute(cancel_caller, mcp_url, pane, tool, arguments, request_id)

      {:error, _reason} = error ->
        error
    end
  end

  defp cancel_tool_call(pane, delivery_context) do
    with :ok <- ensure_ouroboros_pane(pane) do
      resolve_cancel_tool_call(pane, delivery_context)
    end
  end

  # The cancel tools and the `runtime_source: "ouroboros"` envelope are
  # Ouroboros-specific. A focused child pane backed by another runtime
  # (codex/opencode/claude_code) must not be cancelled against the Ouroboros
  # MCP url; job_id/execution_id are only minted for Ouroboros panes today, so
  # this guard is a safety net, not a behaviour change.
  defp ensure_ouroboros_pane(pane) do
    case map_value(pane, :runtime_source) do
      "ouroboros" -> :ok
      :ouroboros -> :ok
      _other -> {:error, {:child_pane_not_cancellable, map_value(pane, :id)}}
    end
  end

  defp resolve_cancel_tool_call(pane, delivery_context) do
    external_ids = map_value(pane, :external_ids) || %{}
    job_id = present_id(external_ids, :job_id)
    execution_id = present_id(external_ids, :execution_id)

    cond do
      is_binary(job_id) ->
        {:ok, "ouroboros_cancel_job", %{"job_id" => job_id}, "child-cancel-job:" <> job_id}

      is_binary(execution_id) ->
        arguments =
          %{"execution_id" => execution_id}
          |> maybe_put_reason(delivery_context)

        {:ok, "ouroboros_cancel_execution", arguments,
         "child-cancel-execution:" <> execution_id}

      true ->
        {:error, {:child_pane_not_cancellable, map_value(pane, :id)}}
    end
  end

  defp execute(cancel_caller, mcp_url, pane, tool, arguments, request_id) do
    result =
      cancel_caller.(
        [
          url: mcp_url,
          parent_call_id: map_value(pane, :parent_call_id) || request_id,
          runtime_source: "ouroboros",
          mcp_session: true,
          timeout: @cancel_timeout_ms
        ],
        cancel_payload(tool, arguments, request_id)
      )

    case result do
      {:ok, call_result} ->
        {:ok, %{tool: tool, arguments: arguments, result: call_result}}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_cancel_call_result, other}}
    end
  rescue
    exception -> {:error, {:cancel_call_failed, exception}}
  end

  defp cancel_payload(tool, arguments, request_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "tools/call",
      "params" => %{"name" => tool, "arguments" => arguments}
    }
  end

  # `ouroboros_cancel_execution` accepts an optional reason; surface the
  # decoded request reason (slash-command args or the default action reason).
  defp maybe_put_reason(arguments, delivery_context) do
    decoded_request = map_value(delivery_context, :decoded_request) || %{}

    case map_value(decoded_request, :reason) do
      reason when is_binary(reason) and reason != "" ->
        Map.put(arguments, "reason", reason)

      _none ->
        arguments
    end
  end

  defp present_id(external_ids, key) do
    case map_value(external_ids, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil
end
