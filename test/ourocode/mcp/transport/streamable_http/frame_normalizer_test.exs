defmodule Ourocode.MCP.Transport.StreamableHTTP.FrameNormalizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.FrameNormalizer

  test "normalizes raw SSE JSON-RPC notification frames into canonical events" do
    frame =
      """
      event: message
      id: progress-1
      data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-http-frame-1","seq":1,"token":"alpha"}}

      """

    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 11,
                type: :parent_call_event,
                transport: :streamable_http,
                parent_call_id: "parent-http-frame-1",
                runtime_source: "synthetic",
                external_ids: %{
                  "session_id" => "session-http-frame-1",
                  childID: "child-http-frame-1"
                },
                occurred_at_ms: 123,
                status: 200,
                headers: [{"content-type", "text/event-stream"}],
                notification: %{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/progress",
                  "params" => %{
                    "childID" => "child-http-frame-1",
                    "seq" => 1,
                    "token" => "alpha"
                  }
                },
                raw_event: %{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/progress",
                  "params" => %{
                    "childID" => "child-http-frame-1",
                    "seq" => 1,
                    "token" => "alpha"
                  }
                }
              }
            ]} = FrameNormalizer.normalize_raw_frame(frame, context())
  end

  test "normalizes raw SSE JSON-RPC response frames into canonical events" do
    frame =
      """
      event: message
      id: done-1
      data: {"jsonrpc":"2.0","id":"call-http-frame-1","result":{"childID":"child-http-frame-2","seq":2,"ok":true}}

      """

    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 11,
                type: :parent_call_result,
                transport: :streamable_http,
                parent_call_id: "parent-http-frame-1",
                request_id: "call-http-frame-1",
                result: %{"childID" => "child-http-frame-2", "seq" => 2, "ok" => true},
                external_ids: %{
                  "session_id" => "session-http-frame-1",
                  childID: "child-http-frame-2"
                }
              }
            ]} = FrameNormalizer.normalize_raw_frame(frame, context())
  end

  test "normalizes raw JSON HTTP response bodies into canonical events" do
    frame =
      ~s({"jsonrpc":"2.0","id":"call-http-frame-json-1","result":{"childID":"child-http-frame-json-1","seq":3,"ok":true}})

    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 11,
                type: :parent_call_result,
                transport: :streamable_http,
                parent_call_id: "parent-http-frame-1",
                request_id: "call-http-frame-json-1",
                result: %{
                  "childID" => "child-http-frame-json-1",
                  "seq" => 3,
                  "ok" => true
                },
                status: 200,
                headers: [{"content-type", "application/json"}],
                external_ids: %{
                  "session_id" => "session-http-frame-1",
                  childID: "child-http-frame-json-1"
                }
              }
            ]} =
             FrameNormalizer.normalize_raw_frame(
               frame,
               Map.put(context(), :headers, [{"content-type", "application/json"}])
             )
  end

  test "normalizes SSE retry metadata frames into transport metadata events" do
    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 11,
                type: :transport_metadata,
                transport: :streamable_http,
                parent_call_id: "parent-http-frame-1",
                payload: %{"reconnection_delay_ms" => 2500},
                raw_event: %{
                  "event" => "message",
                  "id" => nil,
                  "metadata" => %{"reconnection_delay_ms" => 2500},
                  "retry" => 2500
                }
              }
            ]} = FrameNormalizer.normalize_raw_frame("retry: 2500\n\n", context())
  end

  test "turns malformed raw stream frames into decode failure events" do
    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 11,
                type: :transport_decode_failed,
                transport: :streamable_http,
                parent_call_id: "parent-http-frame-1",
                error: _reason,
                raw_event: %{"raw_frame" => "data: {not-json}\n\n"}
              }
            ]} = FrameNormalizer.normalize_raw_frame("data: {not-json}\n\n", context())
  end

  defp context do
    %{
      event_seq: 11,
      parent_call_id: "parent-http-frame-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-http-frame-1"},
      occurred_at_ms: 123,
      status: 200,
      headers: [{"content-type", "text/event-stream"}]
    }
  end
end
