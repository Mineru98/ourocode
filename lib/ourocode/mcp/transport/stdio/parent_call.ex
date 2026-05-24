defmodule Ourocode.MCP.Transport.Stdio.ParentCall do
  @moduledoc """
  Parent JSON-RPC call orchestration for the stdio transport.
  """

  alias Ourocode.MCP.Transport.Stdio.Cleanup
  alias Ourocode.MCP.Transport.Stdio.EventEmitter
  alias Ourocode.MCP.Transport.Stdio.OutboundRequest
  alias Ourocode.MCP.Transport.Stdio.PendingRequest

  @type write_fun :: (map(), map() -> :ok | {:error, term()})

  @spec handle_call(
          map(),
          GenServer.from(),
          String.t(),
          map() | list() | nil,
          keyword(),
          pos_integer(),
          integer(),
          write_fun()
        ) :: {:noreply, map()} | {:reply, {:error, term()}, map()}
  def handle_call(
        state,
        from,
        method,
        params,
        opts,
        default_timeout,
        now_ms,
        write_fun \\ &write_request/2
      )
      when is_map(state) and is_binary(method) and is_list(opts) and
             is_integer(default_timeout) and is_integer(now_ms) and is_function(write_fun, 2) do
    opts = Keyword.put_new(opts, :timeout, default_timeout)
    outbound = OutboundRequest.build(state, method, params, opts, now_ms)
    state = Cleanup.touch(state)

    case write_fun.(state, outbound.request) do
      :ok ->
        timer =
          Process.send_after(self(), {:request_timeout, outbound.request_id}, outbound.timeout)

        pending =
          PendingRequest.new(
            from,
            outbound.method,
            outbound.params,
            outbound.external_ids,
            timer,
            outbound.started_at_ms
          )

        state =
          state
          |> PendingRequest.put(outbound.request_id, pending)
          |> EventEmitter.emit(:parent_call_started, OutboundRequest.started_attrs(outbound))

        {:noreply, state}

      {:error, reason} ->
        state =
          EventEmitter.emit(
            state,
            :parent_call_write_failed,
            OutboundRequest.write_failed_attrs(outbound, reason)
          )

        {:reply, {:error, reason}, state}
    end
  end

  @spec write_request(map(), map()) :: :ok | {:error, term()}
  def write_request(state, request) when is_map(state) and is_map(request) do
    payload = state.codec.encode!(request)

    if Port.command(state.port, [payload, "\n"]) do
      :ok
    else
      {:error, :closed}
    end
  rescue
    exception -> {:error, Exception.message(exception)}
  end
end
