defmodule Ourocode.MCP.Transport.StreamableHTTP.CallContext do
  @moduledoc """
  Request-scoped context projections for Streamable HTTP parent calls.
  """

  alias Ourocode.MCP.ParentCallResult

  @spec normalizer(keyword(), map(), non_neg_integer()) :: map()
  def normalizer(options, request, event_seq)
      when is_list(options) and is_map(request) and is_integer(event_seq) do
    request_id = request["id"] || request[:id]

    %{
      event_seq: event_seq,
      parent_call_id:
        Keyword.get(
          options,
          :parent_call_id,
          normalize_request_id(request_id) || "parent-http-call"
        ),
      runtime_source: Keyword.get(options, :runtime_source, "synthetic"),
      external_ids: Keyword.get(options, :external_ids, %{}),
      request_id: normalize_request_id(request_id),
      method: request["method"] || request[:method],
      params: request["params"] || request[:params],
      occurred_at_ms: System.system_time(:millisecond)
    }
  end

  @spec result(keyword(), non_neg_integer(), [{term(), term()}], map()) :: ParentCallResult.t()
  def result(options, status, headers, response)
      when is_list(options) and is_integer(status) and is_list(headers) and is_map(response) do
    %ParentCallResult{
      parent_call_id: Keyword.get(options, :parent_call_id, response["id"] || "parent-http-call"),
      runtime_source: Keyword.get(options, :runtime_source, "synthetic"),
      transport: :streamable_http,
      external_ids: Keyword.get(options, :external_ids, %{}),
      response: response,
      status: status,
      headers: headers,
      received_at: System.monotonic_time(:millisecond)
    }
  end

  @spec next_event_seq(keyword()) :: non_neg_integer()
  def next_event_seq(options) when is_list(options), do: Keyword.get(options, :event_seq, 0) + 1

  @spec normalize_request_id(term()) :: String.t() | nil
  def normalize_request_id(nil), do: nil
  def normalize_request_id(request_id), do: to_string(request_id)
end
