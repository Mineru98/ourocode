defmodule Ourocode.MCP.Transport.Stdio.OutboundRequest do
  @moduledoc """
  Builds stdio JSON-RPC outbound request metadata.
  """

  alias Ourocode.MCP.RuntimeEventParser
  alias Ourocode.MCP.Transport.Stdio.RawEvent

  @spec build(map(), String.t(), map() | list() | nil, keyword(), integer()) :: map()
  def build(state, method, params, opts, now_ms)
      when is_map(state) and is_binary(method) and is_list(opts) and is_integer(now_ms) do
    request_id = Integer.to_string(state.request_seq + 1)
    request = %{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}
    raw_context = RawEvent.context(state, :outbound, request, now_ms)
    external_ids = Map.merge(state.external_ids, RuntimeEventParser.extract_external_ids(request))

    %{
      request_id: request_id,
      request: request,
      method: method,
      params: params,
      timeout: Keyword.fetch!(opts, :timeout),
      external_ids: external_ids,
      raw_event: RawEvent.annotate(request, raw_context),
      started_at_ms: now_ms
    }
  end

  @spec started_attrs(map()) :: map()
  def started_attrs(%{} = outbound) do
    %{
      external_ids: outbound.external_ids,
      request_id: outbound.request_id,
      method: outbound.method,
      params: outbound.params,
      raw_event: outbound.raw_event
    }
  end

  @spec write_failed_attrs(map(), term()) :: map()
  def write_failed_attrs(%{} = outbound, reason) do
    outbound
    |> started_attrs()
    |> Map.delete(:method)
    |> Map.delete(:params)
    |> Map.put(:error, reason)
  end
end
