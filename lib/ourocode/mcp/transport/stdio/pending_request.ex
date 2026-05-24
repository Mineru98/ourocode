defmodule Ourocode.MCP.Transport.Stdio.PendingRequest do
  @moduledoc """
  Pure pending-request bookkeeping for the stdio transport.
  """

  @spec new(GenServer.from(), String.t(), term(), map(), reference(), integer()) :: map()
  def new(from, method, params, external_ids, timer, started_at_ms) do
    %{
      from: from,
      method: method,
      params: params,
      external_ids: external_ids,
      timer: timer,
      started_at_ms: started_at_ms
    }
  end

  @spec put(map(), String.t(), map()) :: map()
  def put(state, request_id, pending) when is_map(state) and is_binary(request_id) do
    state
    |> Map.update!(:request_seq, &(&1 + 1))
    |> Map.update!(:pending, &Map.put(&1, request_id, pending))
  end

  @spec pop(map(), String.t()) :: {map() | nil, map()}
  def pop(state, request_id) when is_map(state) and is_binary(request_id) do
    {pending, pending_map} = Map.pop(state.pending, request_id)
    {pending, Map.put(state, :pending, pending_map)}
  end

  @spec clear(map()) :: map()
  def clear(state) when is_map(state), do: Map.put(state, :pending, %{})

  @spec reply_from_decoded(map()) :: {:ok, term()} | {:error, term()}
  def reply_from_decoded(decoded) when is_map(decoded) do
    cond do
      Map.has_key?(decoded, "result") -> {:ok, Map.fetch!(decoded, "result")}
      Map.has_key?(decoded, "error") -> {:error, Map.fetch!(decoded, "error")}
      true -> {:error, {:invalid_response, decoded}}
    end
  end

  @spec response_attrs(String.t(), map()) :: map()
  def response_attrs(request_id, pending) when is_binary(request_id) and is_map(pending) do
    %{
      request_id: request_id,
      method: pending.method,
      params: pending.params
    }
  end
end
