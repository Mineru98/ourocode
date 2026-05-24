defmodule Ourocode.MCP.Transport.StreamableHTTP.ResponseEventsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.StreamableHTTP.ResponseEvents

  test "build annotates normalized response events with raw response metadata" do
    request = %{"jsonrpc" => "2.0", "id" => "call-1", "method" => "tools/call"}
    body = Json.encode!(%{"jsonrpc" => "2.0", "id" => "call-1", "result" => %{"ok" => true}})

    assert [event] =
             ResponseEvents.build(
               [
                 url: "http://example.test/mcp",
                 parent_call_id: "parent-1",
                 runtime_source: "test",
                 event_seq: 7
               ],
               request,
               200,
               [{"content-type", "application/json"}],
               IO.iodata_to_binary(body)
             )

    assert event.type == :parent_call_result
    assert event.parent_call_id == "parent-1"
    assert event.request_id == "call-1"
    assert event.event_seq == 8
    assert event.result == %{"ok" => true}

    assert %{
             transport: :streamable_http,
             transport_type: :streamable_http,
             stream_direction: :inbound,
             parent_call_id: "parent-1",
             request_id: "call-1",
             status: 200,
             url: "http://example.test/mcp",
             raw_payload_size_bytes: raw_payload_size_bytes,
             raw_payload_ref: raw_payload_ref
           } = event.raw_event

    assert raw_payload_size_bytes > 0
    assert String.starts_with?(raw_payload_ref, "sha256:")
  end

  test "build returns a failed lifecycle event when response normalization fails" do
    request = %{"jsonrpc" => "2.0", "id" => "call-2", "method" => "tools/call"}

    assert [event] =
             ResponseEvents.build(
               [
                 url: "http://example.test/mcp",
                 parent_call_id: "parent-2",
                 event_seq: 3
               ],
               request,
               200,
               [{"content-type", "application/json"}],
               "{not-json"
             )

    assert event.type == :parent_call_failed
    assert event.parent_call_id == "parent-2"
    assert event.request_id == "call-2"
    assert event.event_seq == 4
    assert event.error
    assert event.raw_event.status == 200
    assert event.raw_event.raw_payload_size_bytes == byte_size("{not-json")
  end
end
