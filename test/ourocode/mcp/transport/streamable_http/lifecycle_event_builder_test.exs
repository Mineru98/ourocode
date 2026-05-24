defmodule Ourocode.MCP.Transport.StreamableHTTP.LifecycleEventBuilderTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleEventBuilder

  test "json_rpc_event converts regular JSON-RPC result payloads" do
    event =
      LifecycleEventBuilder.json_rpc_event(
        %{
          "jsonrpc" => "2.0",
          "id" => 42,
          "result" => %{"ok" => true},
          "external_ids" => %{"trace_id" => "trace-regular"}
        },
        context()
      )

    assert event.type == :parent_call_result
    assert event.request_id == "42"
    assert event.result == %{"ok" => true}

    assert event.external_ids == %{
             "session_id" => "session-1",
             "trace_id" => "trace-regular"
           }
  end

  test "json_rpc_event unwraps lifecycle result envelopes and merges external ids" do
    event =
      LifecycleEventBuilder.json_rpc_event(
        %{
          "jsonrpc" => "2.0",
          "id" => "call-1",
          "external_ids" => %{"trace_id" => "trace-1"},
          "result" => %{
            "type" => "parent_call_result",
            "payload" => %{"childID" => "child-1", "seq" => 2},
            "result" => %{"done" => true},
            "external_ids" => %{"job_id" => "job-1"}
          }
        },
        context()
      )

    assert event.type == :parent_call_result
    assert event.request_id == "call-1"
    assert event.payload == %{"childID" => "child-1", "seq" => 2}
    assert event.result == %{"done" => true}

    assert event.external_ids == %{
             "session_id" => "session-1",
             "trace_id" => "trace-1",
             "job_id" => "job-1",
             childID: "child-1"
           }
  end

  test "json_rpc_event unwraps lifecycle error envelopes" do
    json_rpc_error = %{
      "code" => -32_000,
      "message" => "failed",
      "data" => %{
        "type" => "parent_call_failed",
        "payload" => %{"childID" => "child-2"},
        "error" => %{"reason" => "tool_failed"}
      }
    }

    event =
      LifecycleEventBuilder.json_rpc_event(
        %{"jsonrpc" => "2.0", "id" => "call-2", "error" => json_rpc_error},
        context()
      )

    assert event.type == :parent_call_failed
    assert event.request_id == "call-2"
    assert event.error == %{"reason" => "tool_failed"}
    assert event.error_details == json_rpc_error
    assert event.external_ids == %{"session_id" => "session-1", childID: "child-2"}
  end

  test "started and failed build transport-scoped parent call events" do
    started = LifecycleEventBuilder.started(Map.merge(context(), %{method: "tools/call"}))
    failed = LifecycleEventBuilder.failed(context(), :boom)

    assert started.type == :parent_call_started
    assert started.transport == :streamable_http
    assert started.method == "tools/call"

    assert failed.type == :parent_call_failed
    assert failed.error == :boom
  end

  defp context do
    %{
      event_seq: 5,
      parent_call_id: "parent-1",
      runtime_source: "test",
      external_ids: %{"session_id" => "session-1"},
      occurred_at_ms: 123,
      status: 200,
      headers: [{"content-type", "application/json"}]
    }
  end
end
