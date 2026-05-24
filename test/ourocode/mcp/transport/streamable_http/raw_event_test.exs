defmodule Ourocode.MCP.Transport.StreamableHTTP.RawEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.RawEvent

  test "build_request_record captures outbound correlation and payload hash" do
    request = %{
      "id" => "call-raw-request-1",
      "method" => "tools/call",
      "params" => %{"name" => "demo"}
    }

    context = %{
      parent_call_id: "parent-raw-request-1",
      request_id: "call-raw-request-1",
      method: "tools/call",
      occurred_at_ms: 1_800_000
    }

    raw_payload = request |> Json.encode!() |> IO.iodata_to_binary()
    expected_ref = "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_payload), case: :lower)

    assert %{
             transport: :streamable_http,
             stream_direction: :outbound,
             correlation_id: "call-raw-request-1",
             parent_call_id: "parent-raw-request-1",
             method: "tools/call",
             url: "http://localhost:4000/mcp",
             timestamp_ms: 1_800_000,
             sent_at_ms: 1_800_000,
             raw_payload_ref: ^expected_ref,
             raw_payload_size_bytes: raw_payload_size_bytes
           } = RawEvent.build_request_record([url: "http://localhost:4000/mcp"], request, context)

    assert raw_payload_size_bytes == byte_size(raw_payload)
  end

  test "build_response_record uses response id before context request id" do
    raw_event = %{"id" => "response-id", "result" => %{"ok" => true}, "raw_payload" => "drop-me"}
    raw_payload = raw_event |> Json.encode!() |> IO.iodata_to_binary()

    context = %{
      parent_call_id: "parent-raw-response-1",
      request_id: "context-id",
      occurred_at_ms: 1_900_000
    }

    assert %{
             "id" => "response-id",
             transport: :streamable_http,
             stream_direction: :inbound,
             correlation_id: "response-id",
             request_id: "response-id",
             status: 200,
             received_at_ms: 1_900_000
           } =
             RawEvent.build_response_record(
               [status: 200, headers: [], raw_payload: raw_payload],
               raw_event,
               context
             )

    refute Map.has_key?(
             RawEvent.build_response_record(
               [status: 200, headers: [], raw_payload: raw_payload],
               raw_event,
               context
             ),
             "raw_payload"
           )
  end

  test "canonical_journal_event drops nil values from lifecycle structs and maps" do
    event = %LifecycleEvent{
      type: :parent_call_started,
      event_seq: 1,
      parent_call_id: "parent-1",
      transport: :streamable_http,
      runtime_source: "synthetic",
      external_ids: %{},
      occurred_at_ms: 100,
      request_id: nil
    }

    assert RawEvent.canonical_journal_event(event) == %{
             type: :parent_call_started,
             event_seq: 1,
             parent_call_id: "parent-1",
             transport: :streamable_http,
             runtime_source: "synthetic",
             external_ids: %{},
             occurred_at_ms: 100
           }

    assert RawEvent.canonical_journal_event(%{type: :x, optional: nil}) == %{type: :x}
  end

  test "annotate_response merges existing raw event metadata" do
    event = %LifecycleEvent{
      type: :parent_call_result,
      event_seq: 1,
      transport: :streamable_http,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      external_ids: %{},
      occurred_at_ms: 100,
      raw_event: %{existing: true}
    }

    assert %LifecycleEvent{raw_event: %{existing: true, status: 200}} =
             RawEvent.annotate_response(event, %{status: 200})
  end
end
