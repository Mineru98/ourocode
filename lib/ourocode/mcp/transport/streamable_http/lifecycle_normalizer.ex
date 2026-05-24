defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer do
  @moduledoc """
  Normalizes streamable HTTP MCP parent call lifecycle data.

  Streamable HTTP can return a single JSON-RPC response or a text/event-stream
  body containing JSON-RPC notifications and responses. This module converts
  both forms into typed `Ourocode.MCP.LifecycleEvent` structs.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleEventBuilder
  alias Ourocode.MCP.Transport.StreamableHTTP.SSEBodyParser

  @type context :: %{
          required(:parent_call_id) => String.t(),
          required(:runtime_source) => String.t(),
          required(:external_ids) => map(),
          optional(:event_seq) => non_neg_integer(),
          optional(:request_id) => String.t(),
          optional(:method) => String.t(),
          optional(:params) => map() | list() | nil,
          optional(:occurred_at_ms) => integer(),
          optional(:status) => non_neg_integer(),
          optional(:headers) => [{String.t(), String.t()}]
        }

  @spec started(context()) :: LifecycleEvent.t()
  def started(context) do
    LifecycleEventBuilder.started(context)
  end

  @spec failed(context(), term()) :: LifecycleEvent.t()
  def failed(context, reason) do
    LifecycleEventBuilder.failed(context, reason)
  end

  @spec normalize_body(non_neg_integer(), [{String.t(), String.t()}], String.t(), context()) ::
          {:ok, [LifecycleEvent.t()]} | {:error, term()}
  def normalize_body(status, headers, body, context) when is_binary(body) do
    context =
      context
      |> Map.put(:status, status)
      |> Map.put(:headers, headers)

    if event_stream?(headers) do
      normalize_sse_body(body, context)
    else
      with {:ok, decoded} <- Json.decode(body) do
        {:ok, [LifecycleEventBuilder.json_rpc_event(decoded, context)]}
      end
    end
  end

  @spec parse_sse(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_sse(body) when is_binary(body) do
    SSEBodyParser.parse(body)
  end

  defp normalize_sse_body(body, context) do
    with {:ok, events} <- parse_sse(body) do
      normalize_sse_events(events, context)
    end
  end

  @spec normalize_sse_events([map()], context()) :: {:ok, [LifecycleEvent.t()]}
  def normalize_sse_events(events, context) when is_list(events) and is_map(context) do
    base_seq = Map.get(context, :event_seq, 1) || 1

    lifecycle_events =
      events
      |> Enum.with_index()
      |> Enum.map(fn {event, index} ->
        data = Map.fetch!(event, "data")

        event_context =
          context
          |> Map.put(:event_seq, base_seq + index)
          |> LifecycleEventBuilder.merge_external_ids(event)

        LifecycleEventBuilder.json_rpc_event(data, event_context)
      end)

    {:ok, lifecycle_events}
  end

  defp event_stream?(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(key) == "content-type" and
        value |> String.downcase() |> String.contains?("text/event-stream")
    end)
  end
end
