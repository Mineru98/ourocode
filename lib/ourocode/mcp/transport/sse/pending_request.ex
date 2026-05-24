defmodule Ourocode.MCP.Transport.SSE.PendingRequest do
  @moduledoc """
  Pending parent-call bookkeeping for the SSE transport.
  """

  @spec new(GenServer.from(), String.t(), term(), reference()) :: map()
  def new(from, method, params, timer) do
    %{
      from: from,
      method: method,
      params: params,
      timer: timer
    }
  end

  @spec increment_request_seq(map()) :: map()
  def increment_request_seq(state) when is_map(state) do
    Map.update!(state, :request_seq, &(&1 + 1))
  end

  @spec put(map(), String.t(), map()) :: map()
  def put(state, request_id, pending) when is_map(state) and is_binary(request_id) do
    Map.update!(state, :pending, &Map.put(&1, request_id, pending))
  end

  @spec pop(map(), String.t()) :: {map() | nil, map()}
  def pop(state, request_id) when is_map(state) and is_binary(request_id) do
    {pending, pending_map} = Map.pop(state.pending, request_id)
    {pending, Map.put(state, :pending, pending_map)}
  end

  @spec clear(map()) :: map()
  def clear(state) when is_map(state), do: Map.put(state, :pending, %{})

  @spec context_attrs(map() | nil) :: map()
  def context_attrs(nil), do: %{method: nil, params: nil}

  def context_attrs(pending) when is_map(pending) do
    %{method: pending.method, params: pending.params}
  end

  @spec failed_event_attrs(String.t(), map(), term()) :: map()
  def failed_event_attrs(request_id, pending, reason)
      when is_binary(request_id) and is_map(pending) do
    %{
      request_id: request_id,
      method: pending.method,
      params: pending.params,
      error: reason
    }
  end
end
