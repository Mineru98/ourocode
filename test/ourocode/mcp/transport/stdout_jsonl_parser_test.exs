defmodule Ourocode.MCP.Transport.StdoutJsonlParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.RawProtocolMessage
  alias Ourocode.MCP.Transport.Stdio.LifecycleNormalizer
  alias Ourocode.MCP.Transport.StdoutJsonlParser

  test "decodes valid JSONL object records and ignores malformed or non-JSON lines" do
    jsonl = """
    starting helper process
    {"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-1","seq":1}}
    {malformed json

    ["valid json but not an object"]
    {"jsonrpc":"2.0","id":"1","result":{"ok":true,"seq":2}}
    plain text log line
    """

    assert [
             %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{"childID" => "child-1", "seq" => 1}
             },
             %{"jsonrpc" => "2.0", "id" => "1", "result" => %{"ok" => true, "seq" => 2}}
           ] = StdoutJsonlParser.parse(jsonl)
  end

  test "parses one valid object line" do
    assert {:ok, %{"seq" => 1}} = StdoutJsonlParser.parse_line("  {\"seq\":1}\n")
  end

  test "parses stdout JSONL object lines into typed raw protocol messages" do
    jsonl = """
    helper log before protocol
    {"jsonrpc":"2.0","id":"req-1","method":"tools/call","params":{"name":"lookup"}}
    {"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-1","seq":1}}
    {"jsonrpc":"2.0","id":"req-1","result":{"ok":true}}
    {"jsonrpc":"2.0","id":"req-2","error":{"code":-32000,"message":"failed"}}
    [1,2,3]
    """

    assert [
             %RawProtocolMessage{
               kind: :request,
               jsonrpc: "2.0",
               id: "req-1",
               method: "tools/call",
               params: %{"name" => "lookup"},
               raw: %{"id" => "req-1", "method" => "tools/call"}
             },
             %RawProtocolMessage{
               kind: :notification,
               jsonrpc: "2.0",
               id: nil,
               method: "notifications/progress",
               params: %{"childID" => "child-1", "seq" => 1},
               raw: %{"method" => "notifications/progress"}
             },
             %RawProtocolMessage{
               kind: :response,
               jsonrpc: "2.0",
               id: "req-1",
               result: %{"ok" => true},
               raw: %{"id" => "req-1", "result" => %{"ok" => true}}
             },
             %RawProtocolMessage{
               kind: :error_response,
               jsonrpc: "2.0",
               id: "req-2",
               error: %{"code" => -32000, "message" => "failed"},
               raw: %{"id" => "req-2", "error" => %{"code" => -32000}}
             }
           ] = StdoutJsonlParser.parse_protocol(jsonl)
  end

  test "parses one stdout line into a typed raw notification message" do
    line =
      ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-1"}})

    assert {:ok,
            %RawProtocolMessage{
              kind: :notification,
              raw: %{"jsonrpc" => "2.0"},
              line: ^line
            }} = StdoutJsonlParser.parse_protocol_line(line)
  end

  test "normalizes parsed stdio JSONL protocol messages into shared lifecycle schema" do
    jsonl = """
    {"jsonrpc":"2.0","id":"server-req-1","method":"sampling/createMessage","params":{"childID":"child-normalized-1","seq":1,"token":"ask"}}
    {"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-normalized-1","seq":2,"token":"stream"}}
    {"jsonrpc":"2.0","id":"client-req-1","result":{"ok":true,"childID":"child-normalized-1","seq":3}}
    {"jsonrpc":"2.0","id":"client-req-2","error":{"code":-32000,"message":"failed"}}
    {"jsonrpc":"2.0","unexpected":true}
    """

    [server_request, notification, response, error_response, unknown] =
      StdoutJsonlParser.parse_protocol(jsonl)

    base_context = %{
      event_seq: 10,
      parent_call_id: "parent-normalized-stdio-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-normalized-stdio-1"},
      occurred_at_ms: 123
    }

    assert %{
             type: :parent_call_event,
             transport: :stdio,
             event_seq: 10,
             parent_call_id: "parent-normalized-stdio-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-normalized-stdio-1",
               childID: "child-normalized-1"
             },
             request_id: "server-req-1",
             method: "sampling/createMessage",
             params: %{"childID" => "child-normalized-1", "seq" => 1, "token" => "ask"},
             payload: %{"childID" => "child-normalized-1", "seq" => 1, "token" => "ask"},
             notification: %{"method" => "sampling/createMessage"},
             raw_event: %{"id" => "server-req-1", "method" => "sampling/createMessage"},
             occurred_at_ms: 123
           } = LifecycleNormalizer.normalize_protocol_message(server_request, base_context)

    assert %{
             type: :parent_call_event,
             transport: :stdio,
             event_seq: 11,
             request_id: nil,
             method: nil,
             params: nil,
             payload: %{"childID" => "child-normalized-1", "seq" => 2, "token" => "stream"}
           } =
             LifecycleNormalizer.normalize_protocol_message(notification, %{
               base_context
               | event_seq: 11
             })

    assert %{
             type: :parent_call_result,
             transport: :stdio,
             event_seq: 12,
             request_id: "client-req-1",
             method: "tools/call",
             params: %{"name" => "synthetic.normalized"},
             payload: %{"ok" => true, "childID" => "child-normalized-1", "seq" => 3},
             result: %{"ok" => true, "childID" => "child-normalized-1", "seq" => 3},
             raw_event: %{"id" => "client-req-1", "result" => %{"ok" => true}}
           } =
             LifecycleNormalizer.parent_call_response(
               response.raw,
               {:ok, response.result},
               %{base_context | event_seq: 12},
               %{
                 request_id: "client-req-1",
                 method: "tools/call",
                 params: %{"name" => "synthetic.normalized"}
               }
             )

    assert %{
             type: :parent_call_failed,
             transport: :stdio,
             event_seq: 13,
             request_id: "client-req-2",
             method: "tools/call",
             error: %{"code" => -32000, "message" => "failed"},
             raw_event: %{"id" => "client-req-2", "error" => %{"code" => -32000}}
           } =
             LifecycleNormalizer.parent_call_response(
               error_response.raw,
               {:error, error_response.error},
               %{base_context | event_seq: 13},
               %{request_id: "client-req-2", method: "tools/call"}
             )

    assert %{
             type: :parent_call_unmatched_result,
             transport: :stdio,
             event_seq: 14,
             result: %{"jsonrpc" => "2.0", "unexpected" => true},
             raw_event: %{"jsonrpc" => "2.0", "unexpected" => true}
           } =
             LifecycleNormalizer.normalize_protocol_message(unknown, %{
               base_context
               | event_seq: 14
             })
  end

  test "normalizes parsed stdio lifecycle records into shared event schema" do
    jsonl = """
    {"type":"parent_call_event","payload":{"childID":"child-lifecycle-stdio-1","seq":7,"token":"from-lifecycle"},"notification":{"method":"notifications/progress"},"request_id":"server-lifecycle-1","method":"notifications/progress","params":{"childID":"child-lifecycle-stdio-1","seq":7}}
    {"event_type":"parent_call_result","request_id":"client-lifecycle-1","external_ids":{"thread_id":"thread-lifecycle-stdio-1"},"result":{"ok":true,"childID":"child-lifecycle-stdio-1","seq":8},"payload":{"ok":true,"childID":"child-lifecycle-stdio-1","seq":8}}
    """

    [event_record, result_record] = StdoutJsonlParser.parse_protocol(jsonl)

    base_context = %{
      event_seq: 20,
      parent_call_id: "parent-lifecycle-stdio-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => "session-lifecycle-stdio-1"},
      occurred_at_ms: 456
    }

    assert %LifecycleEvent{
             type: :parent_call_event,
             transport: :stdio,
             event_seq: 20,
             parent_call_id: "parent-lifecycle-stdio-1",
             runtime_source: "synthetic",
             external_ids: %{
               "session_id" => "session-lifecycle-stdio-1",
               childID: "child-lifecycle-stdio-1"
             },
             request_id: "server-lifecycle-1",
             method: "notifications/progress",
             params: %{"childID" => "child-lifecycle-stdio-1", "seq" => 7},
             payload: %{
               "childID" => "child-lifecycle-stdio-1",
               "seq" => 7,
               "token" => "from-lifecycle"
             },
             notification: %{"method" => "notifications/progress"},
             raw_event: %{"type" => "parent_call_event"},
             occurred_at_ms: 456
           } = LifecycleNormalizer.normalize_protocol_message(event_record, base_context)

    assert %LifecycleEvent{
             type: :parent_call_result,
             transport: :stdio,
             event_seq: 21,
             parent_call_id: "parent-lifecycle-stdio-1",
             external_ids: %{
               "session_id" => "session-lifecycle-stdio-1",
               "thread_id" => "thread-lifecycle-stdio-1",
               childID: "child-lifecycle-stdio-1"
             },
             request_id: "client-lifecycle-1",
             payload: %{"ok" => true, "childID" => "child-lifecycle-stdio-1", "seq" => 8},
             result: %{"ok" => true, "childID" => "child-lifecycle-stdio-1", "seq" => 8},
             raw_event: %{"event_type" => "parent_call_result"}
           } =
             LifecycleNormalizer.normalize_protocol_message(result_record, %{
               base_context
               | event_seq: 21
             })
  end

  test "ignores blank, malformed, scalar, and array lines" do
    assert :ignore = StdoutJsonlParser.parse_line("")
    assert :ignore = StdoutJsonlParser.parse_line("not json")
    assert :ignore = StdoutJsonlParser.parse_line("{")
    assert :ignore = StdoutJsonlParser.parse_line("true")
    assert :ignore = StdoutJsonlParser.parse_line("[{\"seq\":1}]")
  end

  test "extracts Codex session_id and thread_id from top-level output records" do
    line = ~s({"type":"session_configured","session_id":"session-1","thread_id":"thread-1"})

    assert {:ok, record, %{session_id: "session-1", thread_id: "thread-1"}} =
             StdoutJsonlParser.parse_codex_line(line)

    assert %{
             "type" => "session_configured",
             "session_id" => "session-1",
             "thread_id" => "thread-1"
           } = record
  end

  test "extracts Codex native_session_id from top-level CLI output records" do
    line =
      ~s({"type":"session_configured","native_session_id":"native-session-1","session_id":"session-1"})

    assert {:ok, record, %{native_session_id: "native-session-1", session_id: "session-1"}} =
             StdoutJsonlParser.parse_codex_line(line)

    assert %{
             "type" => "session_configured",
             "native_session_id" => "native-session-1",
             "session_id" => "session-1"
           } = record
  end

  test "extracts Codex runtime IDs from msg envelope records" do
    record = %{
      "id" => "event-1",
      "msg" => %{
        "type" => "session_configured",
        "session_id" => "session-2",
        "thread_id" => "thread-2"
      }
    }

    assert %{session_id: "session-2", thread_id: "thread-2"} =
             StdoutJsonlParser.extract_codex_external_ids(record)
  end

  test "extracts Codex runtime IDs from supported nested payload and data envelopes" do
    payload_record = %{
      "type" => "event",
      "event" => %{"payload" => %{"session_id" => "session-3"}}
    }

    msg_data_record = %{
      "type" => "codex_event",
      "msg" => %{"data" => %{"thread_id" => "thread-3"}}
    }

    assert %{session_id: "session-3"} =
             StdoutJsonlParser.extract_codex_external_ids(payload_record)

    assert %{thread_id: "thread-3"} =
             StdoutJsonlParser.extract_codex_external_ids(msg_data_record)
  end

  test "extracts Codex native_session_id aliases from supported nested CLI envelopes" do
    payload_record = %{
      "type" => "codex_event",
      "payload" => %{"nativeSessionID" => "native-session-2"}
    }

    input_record = %{
      "type" => "codex_event",
      "input" => %{"nativeSessionId" => "native-session-3"}
    }

    assert %{native_session_id: "native-session-2"} =
             StdoutJsonlParser.extract_codex_external_ids(payload_record)

    assert %{native_session_id: "native-session-3"} =
             StdoutJsonlParser.extract_codex_external_ids(input_record)
  end

  test "ignores missing, blank, and non-string Codex runtime IDs" do
    assert StdoutJsonlParser.extract_codex_external_ids(%{"msg" => %{"type" => "token"}}) == %{}

    assert StdoutJsonlParser.extract_codex_external_ids(%{
             "native_session_id" => "\t",
             "session_id" => " ",
             "thread_id" => 123
           }) == %{}

    assert :ignore = StdoutJsonlParser.parse_codex_line("not json")
  end
end
