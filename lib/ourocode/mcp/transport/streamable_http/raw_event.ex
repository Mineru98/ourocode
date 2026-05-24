defmodule Ourocode.MCP.Transport.StreamableHTTP.RawEvent do
  @moduledoc """
  Raw request/response journal records for Streamable HTTP transport events.
  """

  alias Ourocode.Json

  @spec canonical_journal_event(Ourocode.MCP.LifecycleEvent.t() | map()) :: map()
  def canonical_journal_event(%Ourocode.MCP.LifecycleEvent{} = event) do
    event
    |> Map.from_struct()
    |> compact_journal_event()
  end

  def canonical_journal_event(%{} = event) do
    compact_journal_event(event)
  end

  @spec build_request_record(keyword(), map(), map()) :: map()
  def build_request_record(options, request, context)
      when is_list(options) and is_map(request) and is_map(context) do
    raw_payload = request |> Json.encode!() |> IO.iodata_to_binary()
    request_id = Map.get(context, :request_id)
    timestamp_ms = Map.fetch!(context, :occurred_at_ms)

    %{
      transport: :streamable_http,
      transport_type: :streamable_http,
      stream_direction: :outbound,
      correlation_id: request_id || Map.fetch!(context, :parent_call_id),
      request_id: request_id,
      parent_call_id: Map.fetch!(context, :parent_call_id),
      method: Map.get(context, :method),
      url: Keyword.get(options, :url),
      timestamp_ms: timestamp_ms,
      sent_at_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref(raw_payload),
      raw_payload_size_bytes: byte_size(raw_payload)
    }
  end

  @spec build_response_record(keyword(), map(), map()) :: map()
  def build_response_record(options, raw_event, context)
      when is_list(options) and is_map(raw_event) and is_map(context) do
    raw_payload = Keyword.get(options, :raw_payload, "")
    timestamp_ms = Map.get(context, :occurred_at_ms, System.system_time(:millisecond))
    request_id = response_request_id(raw_event, context)

    Map.merge(raw_event, %{
      transport: :streamable_http,
      transport_type: :streamable_http,
      stream_direction: :inbound,
      correlation_id: request_id || Map.fetch!(context, :parent_call_id),
      request_id: request_id,
      parent_call_id: Map.fetch!(context, :parent_call_id),
      status: Keyword.get(options, :status, Map.get(context, :status)),
      headers: Keyword.get(options, :headers, Map.get(context, :headers)),
      url: Keyword.get(options, :url),
      timestamp_ms: timestamp_ms,
      received_at_ms: timestamp_ms,
      raw_payload_ref: raw_payload_ref(raw_payload),
      raw_payload_size_bytes: byte_size(raw_payload)
    })
    |> Map.delete(:raw_payload)
    |> Map.delete("raw_payload")
  end

  @spec annotate_response(Ourocode.MCP.LifecycleEvent.t(), map()) ::
          Ourocode.MCP.LifecycleEvent.t()
  def annotate_response(%Ourocode.MCP.LifecycleEvent{} = event, response_record) do
    raw_event =
      case event.raw_event do
        raw_event when is_map(raw_event) -> Map.merge(raw_event, response_record)
        _ -> response_record
      end

    %{event | raw_event: raw_event}
  end

  defp compact_journal_event(event) do
    event
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp response_request_id(raw_event, context) do
    cond do
      is_binary(Map.get(raw_event, "id")) -> Map.get(raw_event, "id")
      is_integer(Map.get(raw_event, "id")) -> to_string(Map.get(raw_event, "id"))
      is_binary(Map.get(raw_event, :request_id)) -> Map.get(raw_event, :request_id)
      is_integer(Map.get(raw_event, :request_id)) -> to_string(Map.get(raw_event, :request_id))
      true -> Map.get(context, :request_id)
    end
  end

  defp raw_payload_ref(payload) when is_binary(payload) do
    "sha256:" <>
      (:crypto.hash(:sha256, payload)
       |> Base.encode16(case: :lower))
  end
end
