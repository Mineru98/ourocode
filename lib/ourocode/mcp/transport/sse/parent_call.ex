defmodule Ourocode.MCP.Transport.SSE.ParentCall do
  @moduledoc """
  Parent JSON-RPC call orchestration for the SSE transport.
  """

  alias Ourocode.MCP.Transport.SSE.Dispatch
  alias Ourocode.MCP.Transport.SSE.EventEmitter
  alias Ourocode.MCP.Transport.SSE.PendingRequest

  @spec handle_call(
          map(),
          GenServer.from(),
          String.t(),
          map() | list() | nil,
          keyword(),
          pos_integer()
        ) ::
          {:reply, {:ok, map()} | {:error, term()}, map()} | {:noreply, map()}
  def handle_call(state, from, method, params, opts, default_timeout)
      when is_map(state) and is_binary(method) and is_list(opts) do
    request_id = request_id(state, opts)
    request = request(request_id, method, params)
    timeout = Keyword.get(opts, :timeout, default_timeout)

    case Dispatch.request(state, request, timeout) do
      {:ok, status, response} ->
        handle_dispatched(
          state,
          from,
          method,
          params,
          opts,
          request_id,
          request,
          timeout,
          status,
          response
        )

      {:error, reason} ->
        state =
          EventEmitter.emit(state, :parent_call_write_failed, %{
            request_id: request_id,
            method: method,
            params: params,
            error: reason,
            raw_event: request
          })

        {:reply, {:error, reason}, state}
    end
  end

  @doc false
  @spec request_id(map(), keyword()) :: String.t()
  def request_id(state, opts) when is_map(state) and is_list(opts) do
    opts |> Keyword.get(:request_id, Map.get(state, :request_seq, 0) + 1) |> to_string()
  end

  @doc false
  @spec request(String.t(), String.t(), map() | list() | nil) :: map()
  def request(request_id, method, params) when is_binary(request_id) and is_binary(method) do
    %{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}
  end

  defp handle_dispatched(
         state,
         from,
         method,
         params,
         opts,
         request_id,
         request,
         timeout,
         status,
         response
       ) do
    state =
      state
      |> PendingRequest.increment_request_seq()
      |> EventEmitter.emit(:parent_call_started, %{
        request_id: request_id,
        method: method,
        params: params,
        status: status,
        raw_event: request
      })

    if Keyword.get(opts, :await_response, false) do
      timer = Process.send_after(self(), {:request_timeout, request_id}, timeout)
      pending = PendingRequest.new(from, method, params, timer)

      {:noreply, PendingRequest.put(state, request_id, pending)}
    else
      {:reply, {:ok, %{request_id: request_id, status: status, response: response}}, state}
    end
  end
end
