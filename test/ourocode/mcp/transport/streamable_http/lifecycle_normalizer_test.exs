defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer

  test "normalizes SSE notification and response body frames with sequential event ids" do
    headers = [{"content-type", "text/event-stream"}]

    body = """
    event: message
    data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-1","seq":1}}

    event: message
    data: {"jsonrpc":"2.0","id":"call-1","result":{"childID":"child-1","seq":2,"ok":true}}

    """

    assert {:ok,
            [
              %LifecycleEvent{
                type: :parent_call_event,
                transport: :streamable_http,
                event_seq: 10,
                parent_call_id: "parent-call-1",
                runtime_source: "synthetic",
                external_ids: %{session_id: "session-1"},
                status: 200,
                headers: ^headers,
                notification: %{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/progress",
                  "params" => %{"childID" => "child-1", "seq" => 1}
                }
              },
              %LifecycleEvent{
                type: :parent_call_result,
                transport: :streamable_http,
                event_seq: 11,
                request_id: "call-1",
                result: %{"childID" => "child-1", "seq" => 2, "ok" => true}
              }
            ]} =
             LifecycleNormalizer.normalize_body(200, headers, body, %{
               event_seq: 10,
               parent_call_id: "parent-call-1",
               runtime_source: "synthetic",
               external_ids: %{session_id: "session-1"},
               request_id: "call-1",
               method: "tools/call",
               params: %{name: "ooo.run"},
               occurred_at_ms: 123
             })
  end

  test "normalizes lifecycle response chunks into shared event schema" do
    headers = [{"content-type", "text/event-stream"}]

    body = """
    event: message
    data: {"type":"parent_call_event","payload":{"childID":"child-lifecycle-http-1","seq":7,"token":"from-lifecycle"},"notification":{"method":"notifications/progress"},"request_id":"server-lifecycle-http-1","method":"notifications/progress","params":{"childID":"child-lifecycle-http-1","seq":7}}

    event: message
    data: {"event_type":"parent_call_result","request_id":"client-lifecycle-http-1","external_ids":{"thread_id":"thread-lifecycle-http-1"},"result":{"ok":true,"childID":"child-lifecycle-http-1","seq":8},"payload":{"ok":true,"childID":"child-lifecycle-http-1","seq":8}}

    """

    assert {:ok,
            [
              %LifecycleEvent{
                type: :parent_call_event,
                transport: :streamable_http,
                event_seq: 20,
                parent_call_id: "parent-lifecycle-http-1",
                runtime_source: "synthetic",
                external_ids: %{
                  "session_id" => "session-lifecycle-http-1",
                  childID: "child-lifecycle-http-1"
                },
                request_id: "server-lifecycle-http-1",
                method: "notifications/progress",
                params: %{"childID" => "child-lifecycle-http-1", "seq" => 7},
                payload: %{
                  "childID" => "child-lifecycle-http-1",
                  "seq" => 7,
                  "token" => "from-lifecycle"
                },
                notification: %{"method" => "notifications/progress"},
                raw_event: %{"type" => "parent_call_event"},
                occurred_at_ms: 456,
                status: 200,
                headers: ^headers
              },
              %LifecycleEvent{
                type: :parent_call_result,
                transport: :streamable_http,
                event_seq: 21,
                parent_call_id: "parent-lifecycle-http-1",
                external_ids: %{
                  "session_id" => "session-lifecycle-http-1",
                  "thread_id" => "thread-lifecycle-http-1",
                  childID: "child-lifecycle-http-1"
                },
                request_id: "client-lifecycle-http-1",
                payload: %{"ok" => true, "childID" => "child-lifecycle-http-1", "seq" => 8},
                result: %{"ok" => true, "childID" => "child-lifecycle-http-1", "seq" => 8},
                raw_event: %{"event_type" => "parent_call_result"},
                status: 200,
                headers: ^headers
              }
            ]} =
             LifecycleNormalizer.normalize_body(200, headers, body, %{
               event_seq: 20,
               parent_call_id: "parent-lifecycle-http-1",
               runtime_source: "synthetic",
               external_ids: %{"session_id" => "session-lifecycle-http-1"},
               occurred_at_ms: 456
             })
  end

  test "converts JSON-RPC response lifecycle completion payloads into normalized events" do
    body =
      %{
        "jsonrpc" => "2.0",
        "id" => "call-http-lifecycle-1",
        "result" => %{
          "type" => "parent_call_result",
          "payload" => %{
            "childID" => "child-http-lifecycle-1",
            "seq" => 4,
            "token" => "done"
          },
          "result" => %{"ok" => true},
          "external_ids" => %{"job_id" => "job-http-lifecycle-1"}
        }
      }
      |> Ourocode.Json.encode!()
      |> IO.iodata_to_binary()

    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 9,
                type: :parent_call_result,
                transport: :streamable_http,
                parent_call_id: "parent-http-lifecycle-1",
                runtime_source: "synthetic",
                external_ids: %{
                  "session_id" => "session-http-lifecycle-1",
                  "job_id" => "job-http-lifecycle-1",
                  childID: "child-http-lifecycle-1"
                },
                occurred_at_ms: 123,
                status: 200,
                headers: [{"content-type", "application/json"}],
                request_id: "call-http-lifecycle-1",
                payload: %{
                  "childID" => "child-http-lifecycle-1",
                  "seq" => 4,
                  "token" => "done"
                },
                result: %{"ok" => true},
                raw_event: %{
                  "jsonrpc" => "2.0",
                  "id" => "call-http-lifecycle-1",
                  "result" => %{
                    "type" => "parent_call_result",
                    "payload" => %{
                      "childID" => "child-http-lifecycle-1",
                      "seq" => 4,
                      "token" => "done"
                    },
                    "result" => %{"ok" => true},
                    "external_ids" => %{"job_id" => "job-http-lifecycle-1"}
                  }
                }
              }
            ]} =
             LifecycleNormalizer.normalize_body(
               200,
               [{"content-type", "application/json"}],
               body,
               %{
                 event_seq: 9,
                 parent_call_id: "parent-http-lifecycle-1",
                 runtime_source: "synthetic",
                 external_ids: %{"session_id" => "session-http-lifecycle-1"},
                 occurred_at_ms: 123
               }
             )
  end

  test "converts JSON-RPC lifecycle error payloads into normalized events" do
    body =
      %{
        "jsonrpc" => "2.0",
        "id" => "call-http-lifecycle-error-1",
        "error" => %{
          "code" => -32_000,
          "message" => "child failed",
          "data" => %{
            "type" => "parent_call_failed",
            "payload" => %{
              "childID" => "child-http-lifecycle-error-1",
              "seq" => 5,
              "token" => "failed"
            },
            "error" => %{"reason" => "tool_failed"},
            "external_ids" => %{"job_id" => "job-http-lifecycle-error-1"}
          }
        }
      }
      |> Ourocode.Json.encode!()
      |> IO.iodata_to_binary()

    json_rpc_error = %{
      "code" => -32_000,
      "message" => "child failed",
      "data" => %{
        "type" => "parent_call_failed",
        "payload" => %{
          "childID" => "child-http-lifecycle-error-1",
          "seq" => 5,
          "token" => "failed"
        },
        "error" => %{"reason" => "tool_failed"},
        "external_ids" => %{"job_id" => "job-http-lifecycle-error-1"}
      }
    }

    assert {:ok,
            [
              %LifecycleEvent{
                event_seq: 10,
                type: :parent_call_failed,
                transport: :streamable_http,
                parent_call_id: "parent-http-lifecycle-error-1",
                runtime_source: "synthetic",
                external_ids: %{
                  "session_id" => "session-http-lifecycle-error-1",
                  "job_id" => "job-http-lifecycle-error-1",
                  childID: "child-http-lifecycle-error-1"
                },
                occurred_at_ms: 456,
                status: 200,
                headers: [{"content-type", "application/json"}],
                request_id: "call-http-lifecycle-error-1",
                payload: %{
                  "childID" => "child-http-lifecycle-error-1",
                  "seq" => 5,
                  "token" => "failed"
                },
                error: %{"reason" => "tool_failed"},
                error_details: ^json_rpc_error,
                raw_event: %{
                  "jsonrpc" => "2.0",
                  "id" => "call-http-lifecycle-error-1",
                  "error" => ^json_rpc_error
                }
              }
            ]} =
             LifecycleNormalizer.normalize_body(
               200,
               [{"content-type", "application/json"}],
               body,
               %{
                 event_seq: 10,
                 parent_call_id: "parent-http-lifecycle-error-1",
                 runtime_source: "synthetic",
                 external_ids: %{"session_id" => "session-http-lifecycle-error-1"},
                 occurred_at_ms: 456
               }
             )
  end
end
