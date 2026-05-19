defmodule Ourocode.MCP.Transport.Stdio.LifecycleNormalizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio.LifecycleNormalizer
  alias Ourocode.MCP.Transport.StdoutJsonlParser

  test "converts stdio JSON-RPC request frames into the shared normalized event shape" do
    frame =
      ~s({"jsonrpc":"2.0","id":"server-stdio-1","method":"sampling/createMessage","params":{"childID":"child-stdio-normalizer-1","seq":1,"token":"ask"}})

    assert {:ok, raw_message} = StdoutJsonlParser.parse_protocol_line(frame)

    assert %LifecycleEvent{
             event_seq: 7,
             type: :parent_call_event,
             transport: :stdio,
             parent_call_id: "parent-stdio-normalizer-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-stdio-normalizer-1",
               childID: "child-stdio-normalizer-1"
             },
             occurred_at_ms: 123,
             request_id: "server-stdio-1",
             method: "sampling/createMessage",
             params: %{
               "childID" => "child-stdio-normalizer-1",
               "seq" => 1,
               "token" => "ask"
             },
             notification: %{
               "jsonrpc" => "2.0",
               "id" => "server-stdio-1",
               "method" => "sampling/createMessage",
               "params" => %{
                 "childID" => "child-stdio-normalizer-1",
                 "seq" => 1,
                 "token" => "ask"
               }
             },
             payload: %{
               "childID" => "child-stdio-normalizer-1",
               "seq" => 1,
               "token" => "ask"
             },
             raw_event: %{
               "jsonrpc" => "2.0",
               "id" => "server-stdio-1",
               "method" => "sampling/createMessage",
               "params" => %{
                 "childID" => "child-stdio-normalizer-1",
                 "seq" => 1,
                 "token" => "ask"
               }
             }
           } = LifecycleNormalizer.normalize_protocol_message(raw_message, context())
  end

  test "converts stdio JSON-RPC notification frames into the shared normalized event shape" do
    frame =
      ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-stdio-normalizer-2","seq":2,"token":"stream"}})

    assert {:ok, raw_message} = StdoutJsonlParser.parse_protocol_line(frame)

    assert %LifecycleEvent{
             event_seq: 7,
             type: :parent_call_event,
             transport: :stdio,
             parent_call_id: "parent-stdio-normalizer-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-stdio-normalizer-1",
               childID: "child-stdio-normalizer-2"
             },
             occurred_at_ms: 123,
             request_id: nil,
             method: nil,
             params: nil,
             notification: %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "childID" => "child-stdio-normalizer-2",
                 "seq" => 2,
                 "token" => "stream"
               }
             },
             payload: %{
               "childID" => "child-stdio-normalizer-2",
               "seq" => 2,
               "token" => "stream"
             }
           } = LifecycleNormalizer.normalize_protocol_message(raw_message, context())
  end

  test "converts stdio JSON-RPC response frames into normalized parent call results" do
    frame =
      ~s({"jsonrpc":"2.0","id":"call-stdio-1","result":{"childID":"child-stdio-normalizer-3","seq":3,"ok":true}})

    assert {:ok, raw_message} = StdoutJsonlParser.parse_protocol_line(frame)

    assert %LifecycleEvent{
             event_seq: 7,
             type: :parent_call_result,
             transport: :stdio,
             parent_call_id: "parent-stdio-normalizer-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-stdio-normalizer-1",
               childID: "child-stdio-normalizer-3"
             },
             occurred_at_ms: 123,
             request_id: "call-stdio-1",
             method: "tools/call",
             params: %{"name" => "ooo.run"},
             payload: %{"childID" => "child-stdio-normalizer-3", "seq" => 3, "ok" => true},
             result: %{"childID" => "child-stdio-normalizer-3", "seq" => 3, "ok" => true},
             raw_event: %{
               "jsonrpc" => "2.0",
               "id" => "call-stdio-1",
               "result" => %{"childID" => "child-stdio-normalizer-3", "seq" => 3, "ok" => true}
             }
           } =
             LifecycleNormalizer.parent_call_response(
               raw_message.raw,
               {:ok, raw_message.result},
               context(),
               %{request_id: "call-stdio-1", method: "tools/call", params: %{"name" => "ooo.run"}}
             )
  end

  test "converts stdio lifecycle record frames into canonical lifecycle events" do
    frame =
      ~s({"type":"parent_call_result","request_id":"call-stdio-lifecycle-1","external_ids":{"thread_id":"thread-stdio-normalizer-1"},"payload":{"childID":"child-stdio-normalizer-4","seq":4,"token":"done"},"result":{"ok":true}})

    assert {:ok, raw_message} = StdoutJsonlParser.parse_protocol_line(frame)

    assert %LifecycleEvent{
             event_seq: 7,
             type: :parent_call_result,
             transport: :stdio,
             parent_call_id: "parent-stdio-normalizer-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-stdio-normalizer-1",
               "thread_id" => "thread-stdio-normalizer-1",
               childID: "child-stdio-normalizer-4"
             },
             occurred_at_ms: 123,
             request_id: "call-stdio-lifecycle-1",
             payload: %{
               "childID" => "child-stdio-normalizer-4",
               "seq" => 4,
               "token" => "done"
             },
             result: %{"ok" => true},
             raw_event: %{
               "type" => "parent_call_result",
               "request_id" => "call-stdio-lifecycle-1",
               "external_ids" => %{"thread_id" => "thread-stdio-normalizer-1"},
               "payload" => %{
                 "childID" => "child-stdio-normalizer-4",
                 "seq" => 4,
                 "token" => "done"
               },
               "result" => %{"ok" => true}
             }
           } = LifecycleNormalizer.normalize_protocol_message(raw_message, context())
  end

  defp context do
    %{
      event_seq: 7,
      parent_call_id: "parent-stdio-normalizer-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-stdio-normalizer-1"},
      occurred_at_ms: 123
    }
  end
end
