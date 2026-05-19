defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer

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
