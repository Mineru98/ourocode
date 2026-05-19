defmodule Ourocode.MCP.Transport.SSE.LifecycleNormalizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.SSE.{LifecycleNormalizer, Parser}

  test "converts parsed SSE MCP notifications into the shared normalized event shape" do
    frame = """
    event: child-token
    id: sse-frame-1
    data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-sse-1","seq":1,"token":"hello"}}

    """

    assert {:ok, [parsed_event], ""} = Parser.parse_complete_frames(frame)

    assert %LifecycleEvent{
             event_seq: 7,
             type: :parent_call_event,
             transport: :sse,
             parent_call_id: "parent-sse-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-sse-1",
               childID: "child-sse-1"
             },
             occurred_at_ms: 123,
             status: 200,
             headers: [{"content-type", "text/event-stream"}],
             notification: %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{"childID" => "child-sse-1", "seq" => 1, "token" => "hello"}
             },
             payload: %{"childID" => "child-sse-1", "seq" => 1, "token" => "hello"},
             raw_event: %{
               "event" => "child-token",
               "id" => "sse-frame-1",
               "data" => %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/progress",
                 "params" => %{"childID" => "child-sse-1", "seq" => 1, "token" => "hello"}
               }
             }
           } =
             LifecycleNormalizer.normalize_parsed_event(parsed_event, %{
               event_seq: 7,
               parent_call_id: "parent-sse-1",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-sse-1"},
               occurred_at_ms: 123,
               status: 200,
               headers: [{"content-type", "text/event-stream"}]
             })
  end

  test "converts parsed SSE MCP responses into normalized parent call results" do
    parsed_event = %{
      "event" => "message",
      "id" => "sse-frame-result",
      "data" => %{
        "jsonrpc" => "2.0",
        "id" => "call-sse-1",
        "result" => %{"childID" => "child-sse-1", "seq" => 2, "ok" => true}
      }
    }

    assert %LifecycleEvent{
             event_seq: 8,
             type: :parent_call_result,
             transport: :sse,
             parent_call_id: "parent-sse-1",
             request_id: "call-sse-1",
             call_id: "call-sse-1",
             method: "tools/call",
             params: %{"name" => "ooo.run"},
             payload: %{"childID" => "child-sse-1", "seq" => 2, "ok" => true},
             result: %{"childID" => "child-sse-1", "seq" => 2, "ok" => true},
             external_ids: %{
               "session_id" => "session-sse-1",
               childID: "child-sse-1"
             },
             raw_event: ^parsed_event
           } =
             LifecycleNormalizer.normalize_parsed_event(parsed_event, %{
               event_seq: 8,
               parent_call_id: "parent-sse-1",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-sse-1"},
               method: "tools/call",
               params: %{"name" => "ooo.run"}
             })
  end

  test "preserves SSE metadata records in the canonical transport metadata shape" do
    parsed_event = %{
      "event" => "message",
      "id" => nil,
      "retry" => 1_500,
      "metadata" => %{"reconnection_delay_ms" => 1_500}
    }

    assert %LifecycleEvent{
             event_seq: 9,
             type: :transport_metadata,
             transport: :sse,
             parent_call_id: "parent-sse-1",
             runtime_source: "synthetic",
             external_ids: %{"session_id" => "session-sse-1"},
             occurred_at_ms: 123,
             payload: %{"reconnection_delay_ms" => 1_500},
             raw_event: ^parsed_event
           } = LifecycleNormalizer.normalize_parsed_event(parsed_event, context(event_seq: 9))
  end

  test "applies canonical defaults when optional context fields are omitted" do
    parsed_event = %{
      "event" => "message",
      "id" => "sse-frame-defaults",
      "data" => %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-sse-defaults", "seq" => 3}
      }
    }

    before_normalize_ms = System.system_time(:millisecond)

    assert %LifecycleEvent{
             event_seq: 10,
             type: :parent_call_event,
             transport: :sse,
             parent_call_id: "parent-sse-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-sse-1",
               childID: "child-sse-defaults"
             },
             status: nil,
             headers: nil,
             occurred_at_ms: occurred_at_ms,
             payload: %{"childID" => "child-sse-defaults", "seq" => 3},
             raw_event: ^parsed_event
           } =
             LifecycleNormalizer.normalize_parsed_event(
               parsed_event,
               context(event_seq: 10) |> Map.delete(:occurred_at_ms)
             )

    assert occurred_at_ms >= before_normalize_ms
    assert occurred_at_ms <= System.system_time(:millisecond)
  end

  test "maps invalid parsed SSE records into a journalable decode failure event" do
    parsed_event = %{
      "event" => "heartbeat",
      "id" => "sse-frame-invalid",
      "external_ids" => %{"stream_id" => "stream-sse-invalid-1"}
    }

    assert %LifecycleEvent{
             event_seq: 11,
             type: :transport_decode_failed,
             transport: :sse,
             parent_call_id: "parent-sse-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-sse-1",
               "stream_id" => "stream-sse-invalid-1"
             },
             occurred_at_ms: 123,
             error: {:invalid_sse_event, :missing_data_or_metadata},
             error_details: %{
               reason: :missing_data_or_metadata,
               required_any_of: ["data", "metadata"]
             },
             raw_event: ^parsed_event
           } = LifecycleNormalizer.normalize_parsed_event(parsed_event, context(event_seq: 11))
  end

  defp context(overrides) do
    %{
      event_seq: 7,
      parent_call_id: "parent-sse-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-sse-1"},
      occurred_at_ms: 123
    }
    |> Map.merge(Map.new(overrides))
  end
end
