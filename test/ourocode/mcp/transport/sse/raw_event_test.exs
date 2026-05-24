defmodule Ourocode.MCP.Transport.SSE.RawEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.SSE.RawEvent

  test "frame_metadata preserves explicit id and event fields" do
    assert RawEvent.frame_metadata("event: child-token\nid: frame-1\ndata: {}\n\n") == %{
             sse_event_id: "frame-1",
             sse_event_id_present: true,
             sse_event_type: "child-token",
             sse_event_type_present: true
           }
  end

  test "build_record stores raw payload out of band and removes frame bytes" do
    store_dir =
      Path.join(System.tmp_dir!(), "ourocode-sse-raw-event-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(store_dir) end)

    raw_payload = "event: message\nid: frame-2\ndata: {\"ok\":true}\n\n"
    expected_ref = "sha256:" <> Base.encode16(:crypto.hash(:sha256, raw_payload), case: :lower)

    record =
      RawEvent.build_record(
        %{"id" => "frame-2", frame: raw_payload},
        %{
          endpoint_url: "http://localhost:4001/events",
          connection_identifier: "connection-1",
          session_identifier: "session-1",
          raw_payload: raw_payload,
          raw_payload_store_dir: store_dir,
          timestamp_ms: 200
        }
      )

    assert %{
             transport: :sse,
             transport_type: :sse,
             endpoint_url: "http://localhost:4001/events",
             connection_identifier: "connection-1",
             session_identifier: "session-1",
             raw_payload_ref: ^expected_ref,
             raw_payload_stored?: true,
             raw_payload_size_bytes: raw_payload_size,
             timestamp_ms: 200
           } = record

    assert raw_payload_size == byte_size(raw_payload)
    refute Map.has_key?(record, :frame)
    assert {:ok, ^raw_payload} = File.read(RawEvent.raw_payload_path(store_dir, expected_ref))
  end

  test "build_record preserves explicit absence of event id and type" do
    record =
      RawEvent.build_record(
        %{
          "event" => "message",
          "id" => nil,
          "data" => %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
        },
        %{
          endpoint_url: "http://localhost:4001/events",
          connection_identifier: "connection-absent",
          session_identifier: "session-absent",
          sse_event_id: nil,
          sse_event_id_present: false,
          sse_event_type: nil,
          sse_event_type_present: false,
          timestamp_ms: 300
        }
      )

    assert %{
             "event" => "message",
             "id" => nil,
             sse_event_id: nil,
             sse_event_id_present: false,
             sse_event_type: nil,
             sse_event_type_present: false
           } = record
  end

  test "context derives frame metadata and stable payload reference" do
    raw_payload = "event: child-token\nid: frame-3\ndata: {}\n\n"

    context =
      RawEvent.context(
        %{
          endpoint_url: "http://localhost:4001/events",
          connection_identifier: "connection-2",
          session_identifier: "session-2",
          raw_payload_store_dir: nil
        },
        raw_payload
      )

    assert context.sse_event_id == "frame-3"
    assert context.sse_event_type == "child-token"
    assert context.raw_payload_stored? == false
    assert context.raw_payload_size_bytes == byte_size(raw_payload)
    assert String.starts_with?(context.raw_payload_ref, "sha256:")
  end

  test "canonical_journal_event drops nil values" do
    event = %LifecycleEvent{
      type: :transport_connected,
      event_seq: 1,
      transport: :sse,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      external_ids: %{},
      occurred_at_ms: 100,
      request_id: nil
    }

    assert RawEvent.canonical_journal_event(event) == %{
             type: :transport_connected,
             event_seq: 1,
             transport: :sse,
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             external_ids: %{},
             occurred_at_ms: 100
           }
  end
end
