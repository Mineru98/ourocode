defmodule Ourocode.MCP.Transport.StreamableHTTP.ResponseEvents do
  @moduledoc """
  Converts non-streaming Streamable HTTP response bodies into lifecycle events.
  """

  alias Ourocode.MCP.Transport.StreamableHTTP.CallContext
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer
  alias Ourocode.MCP.Transport.StreamableHTTP.RawEvent

  @spec build(keyword(), map(), non_neg_integer(), [{term(), term()}], binary()) :: [
          Ourocode.MCP.LifecycleEvent.t()
        ]
  def build(options, request, status, headers, body)
      when is_list(options) and is_map(request) and is_integer(status) and is_list(headers) and
             is_binary(body) do
    context = CallContext.normalizer(options, request, Keyword.get(options, :event_seq, 1) + 1)
    response_record = response_record(options, status, headers, body, context)

    case LifecycleNormalizer.normalize_body(status, headers, body, context) do
      {:ok, events} ->
        Enum.map(events, &RawEvent.annotate_response(&1, response_record))

      {:error, reason} ->
        [
          context
          |> LifecycleNormalizer.failed(reason)
          |> RawEvent.annotate_response(response_record)
        ]
    end
  end

  defp response_record(options, status, headers, body, context) do
    RawEvent.build_response_record(
      [
        url: Keyword.get(options, :url),
        status: status,
        headers: headers,
        raw_payload: body
      ],
      %{},
      context
    )
  end
end
