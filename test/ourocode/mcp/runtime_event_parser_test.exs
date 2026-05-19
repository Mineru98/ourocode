defmodule Ourocode.MCP.RuntimeEventParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.RuntimeEventParser

  test "extracts Codex session_id, thread_id, and native_session_id from top-level events" do
    event = %{
      "type" => "session_configured",
      "session_id" => " session-1 ",
      "thread_id" => "thread-1",
      "native_session_id" => "native-session-1"
    }

    assert %{
             session_id: "session-1",
             thread_id: "thread-1",
             native_session_id: "native-session-1"
           } = RuntimeEventParser.extract_external_ids(event)
  end

  test "extracts supported Codex camel-case aliases from nested message payloads" do
    event = %{
      "type" => "codex_event",
      "msg" => %{
        "payload" => %{
          "sessionId" => "session-2",
          "threadID" => "thread-2",
          "nativeSessionID" => "native-session-2"
        }
      }
    }

    assert %{
             session_id: "session-2",
             thread_id: "thread-2",
             native_session_id: "native-session-2"
           } = RuntimeEventParser.extract_external_ids(event)
  end

  test "extracts CLI hook input session IDs from supported event payloads" do
    event = %{
      "type" => "hook_event",
      "params" => %{
        "input" => %{
          "sessionID" => "cli-session-1"
        }
      }
    }

    assert %{session_id: "cli-session-1"} = RuntimeEventParser.extract_external_ids(event)
  end

  test "preserves OpenCode parent call input sessionID and callID identity" do
    event = %{
      "type" => "opencode_parent_call",
      "params" => %{
        "input" => %{
          "sessionID" => " opencode-session-1 ",
          "callID" => " opencode-call-1 ",
          "task" => "inspect stream"
        }
      }
    }

    assert %{
             session_id: "opencode-session-1",
             input_session_id: "opencode-session-1",
             input_call_id: "opencode-call-1",
             input: %{"sessionID" => "opencode-session-1", "callID" => "opencode-call-1"}
           } = RuntimeEventParser.extract_external_ids(event)
  end

  test "preserves OpenCode child session childID, job_id, session_id, execution_id, and lineage_id" do
    event = %{
      "type" => "opencode_child_session",
      "event" => %{
        "data" => %{
          "params" => %{
            "childID" => " opencode-child-1 ",
            "jobID" => " opencode-job-1 ",
            "sessionID" => " opencode-session-1 ",
            "executionId" => " opencode-execution-1 ",
            "lineageId" => " opencode-lineage-1 "
          }
        }
      }
    }

    assert %{
             childID: "opencode-child-1",
             job_id: "opencode-job-1",
             session_id: "opencode-session-1",
             execution_id: "opencode-execution-1",
             lineage_id: "opencode-lineage-1"
           } = RuntimeEventParser.extract_external_ids(event)
  end

  test "extracts runtime IDs from decoded SSE data params and result envelopes" do
    notification = %{
      "event" => "message",
      "id" => "sse-event-1",
      "data" => %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{
          "threadId" => "thread-sse-1",
          "metadata" => %{"sessionId" => "session-sse-1"}
        }
      }
    }

    result = %{
      raw_event: %{
        "event" => "message",
        "data" => %{
          "jsonrpc" => "2.0",
          "id" => "call-1",
          "result" => %{"native_session_id" => "native-sse-1"}
        }
      }
    }

    assert %{thread_id: "thread-sse-1", session_id: "session-sse-1"} =
             RuntimeEventParser.extract_external_ids(notification)

    assert %{native_session_id: "native-sse-1"} =
             RuntimeEventParser.extract_external_ids(result)
  end

  test "extracts IDs from atom-key lifecycle event structs without guessing unsupported paths" do
    event =
      LifecycleEvent.new(:parent_call_event, %{
        event_seq: 1,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "codex",
        external_ids: %{},
        occurred_at_ms: 100,
        raw_event: %{event: %{data: %{threadId: "thread-3"}}}
      })

    assert %{thread_id: "thread-3"} = RuntimeEventParser.extract_external_ids(event)
  end

  test "ignores missing, blank, and non-string runtime IDs" do
    assert RuntimeEventParser.extract_external_ids(%{"msg" => %{"type" => "token"}}) == %{}

    assert RuntimeEventParser.extract_external_ids(%{
             "native_session_id" => "\t",
             "session_id" => " ",
             "thread_id" => 123
           }) == %{}

    assert RuntimeEventParser.extract_external_ids(%{
             "metadata" => %{"session_id" => "hidden"}
           }) == %{}
    assert RuntimeEventParser.extract_external_ids(nil) == %{}
  end
end
