defmodule Ourocode.MCP.ChildSessionCreationParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ChildSessionCreationParser
  alias Ourocode.MCP.LifecycleEvent

  test "extracts childID from JSON-RPC notification params" do
    event =
      LifecycleEvent.new(:parent_call_event, %{
        event_seq: 1,
        transport: :streamable_http,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"session_id" => "session-1"},
        occurred_at_ms: 100,
        notification: %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{"childID" => "child-1", "seq" => 1}
               }
             })

    assert {:ok,
            %{
              child_id: "child-1",
              pane_key: "child-session:child-1",
              source: :childID,
              payload_path: :notification_params
            }} = ChildSessionCreationParser.extract(event)
  end

  test "extracts child_id from parent call result payloads" do
    event = %{
      type: :parent_call_result,
      transport: :sse,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      external_ids: %{},
      result: %{"child_id" => "child-2", "seq" => 1, "ok" => true}
    }

    assert {:ok, "child-2"} = ChildSessionCreationParser.extract_child_id(event)
    assert {:ok, "child-session:child-2"} = ChildSessionCreationParser.extract_pane_key(event)
  end

  test "extracts childID from direct params and raw event result payloads" do
    assert {:ok, %{child_id: "child-3", payload_path: :params}} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_started,
               params: %{childID: " child-3 "}
             })

    assert {:ok, %{child_id: "child-4", payload_path: :raw_event_result}} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_result,
               raw_event: %{"result" => %{"childID" => "child-4"}}
             })

    assert {:ok, %{child_id: "child-5", payload_path: :params}} =
             ChildSessionCreationParser.extract(%{
               "type" => "parent_call_started",
               "params" => %{"childID" => "child-5"}
             })
  end

  test "normalizes SSE child agent and session identity aliases into stable pane keys" do
    examples = [
      {"childID", " child-sse-alias-1 ", :childID},
      {"childId", "child-sse-alias-1", :childId},
      {"child_id", "child-sse-alias-1", :child_id},
      {"childSessionID", "child-sse-alias-1", :child_session_id},
      {"agentSessionId", "child-sse-alias-1", :agent_session_id},
      {"opencode_childID", "child-sse-alias-1", :opencode_child_id}
    ]

    for {field, value, source} <- examples do
      assert {:ok,
              %{
                child_id: "child-sse-alias-1",
                pane_key: "child-session:child-sse-alias-1",
                source: ^source,
                payload_path: :raw_event_data_params
              }} =
               ChildSessionCreationParser.extract(%{
                 type: :parent_call_event,
                 transport: :sse,
                 raw_event: %{
                   "event" => "message",
                   "data" => %{
                     "jsonrpc" => "2.0",
                     "method" => "notifications/progress",
                     "params" => %{field => value, "seq" => 1}
                   }
                 }
               })
    end

    assert {:ok,
            %{
              child_id: "fallback:session_id:session-sse-alias-1",
              pane_key: "child-session:fallback:session_id:session-sse-alias-1",
              source: {:fallback, :session_id},
              payload_path: :fallback_runtime_id
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_event,
               transport: :sse,
               parent_call_id: "parent-sse-alias-1",
               runtime_source: "codex",
               raw_event: %{
                 "event" => "message",
                 "data" => %{
                   "jsonrpc" => "2.0",
                   "method" => "notifications/progress",
                   "params" => %{"sessionID" => " session-sse-alias-1 ", "seq" => 1}
                 }
               }
             })
  end

  test "extracts childID from raw SSE data notification and result envelopes" do
    assert {:ok,
            %{
              child_id: "child-sse-1",
              source: :childID,
              payload_path: :raw_event_data_params
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_event,
               transport: :sse,
               raw_event: %{
                 "event" => "message",
                 "data" => %{
                   "jsonrpc" => "2.0",
                   "method" => "notifications/progress",
                   "params" => %{"childID" => "child-sse-1", "seq" => 1}
                 }
               }
             })

    assert {:ok,
            %{
              child_id: "child-sse-2",
              source: :childID,
              payload_path: :raw_event_data_result
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_result,
               transport: :sse,
               raw_event: %{
                 "event" => "message",
                 "data" => %{
                   "jsonrpc" => "2.0",
                   "id" => "call-1",
                   "result" => %{"childID" => "child-sse-2", "seq" => 2}
                 }
               }
             })
  end

  test "extracts child identity from an SSE-derived pane key" do
    assert {:ok,
            %{
              child_id: "child-sse-pane-1",
              pane_key: "child-session:child-sse-pane-1",
              source: :pane_key,
              payload_path: :raw_event_data_params
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_event,
               transport: :sse,
               raw_event: %{
                 "event" => "message",
                 "data" => %{
                   "jsonrpc" => "2.0",
                   "method" => "notifications/progress",
                   "params" => %{
                     "pane_key" => "child-session:child-sse-pane-1",
                     "seq" => 1
                   }
                 }
               }
             })
  end

  test "extracts explicit childID alternatives from SSE lifecycle fields" do
    assert {:ok,
            %{
              child_id: "child-sse-3",
              source: :child_id,
              payload_path: :result
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_result,
               transport: :sse,
               result: %{"child_id" => "child-sse-3"}
             })

    assert {:ok,
            %{
              child_id: "child-sse-4",
              source: :opencode_child_id,
              payload_path: :notification_params
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_event,
               transport: :sse,
               notification: %{
                 "method" => "notifications/progress",
                 "params" => %{"opencode_childID" => "child-sse-4"}
               }
             })
  end

  test "identifies child session creation events without childID from runtime IDs" do
    event = %{
      type: :parent_call_started,
      transport: :stdio,
      parent_call_id: "parent-create-1",
      runtime_source: "opencode",
      external_ids: %{
        "session_id" => "session-create-1",
        "thread_id" => "thread-create-1"
      },
      method: "agent/session/create",
      params: %{"task" => "summarize failing tests"}
    }

    assert {:ok,
            %{
              child_id: "fallback:thread_id:thread-create-1",
              pane_key: "child-session:fallback:thread_id:thread-create-1",
              source: {:fallback, :thread_id},
              payload_path: :fallback_runtime_id
            }} = ChildSessionCreationParser.extract(event)
  end

  test "retains OpenCode evolutionary lineage identity for child panes when childID is absent" do
    event = %{
      type: :parent_call_started,
      transport: :stdio,
      parent_call_id: "parent-lineage-1",
      runtime_source: "opencode",
      external_ids: %{},
      method: "agent/session/create",
      params: %{
        "input" => %{
          "sessionID" => " opencode-session-lineage-1 ",
          "callID" => " opencode-call-lineage-1 "
        },
        "lineageId" => " opencode-lineage-1 ",
        "task" => "evolve this implementation"
      }
    }

    assert {:ok,
            %{
              child_id: "fallback:lineage_id:opencode-lineage-1",
              pane_key: "child-session:fallback:lineage_id:opencode-lineage-1",
              source: {:fallback, :lineage_id},
              payload_path: :fallback_runtime_id
            }} = ChildSessionCreationParser.extract(event)
  end

  test "returns explicit unresolved result when no fallback runtime metadata exists" do
    assert {:unresolved,
            %{
              status: :unresolved,
              reason: :missing_fallback_runtime_metadata,
              parent_call_id: "parent-unresolved-1",
              checked_sources: [
                :execution_id,
                :job_id,
                :lineage_id,
                :native_session_id,
                :thread_id,
                :session_id,
                :input_session_id,
                :input_call_id,
                :call_id,
                :request_id
              ]
            }} =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_event,
               transport: :stdio,
               parent_call_id: "parent-unresolved-1",
               runtime_source: "codex",
               external_ids: %{
                 "session_id" => " ",
                 thread_id: nil,
                 job_id: []
               },
               fallback_runtime_metadata: %{},
               notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
             })
  end

  test "ignores events without explicit child session identifiers" do
    assert :ignore =
             ChildSessionCreationParser.extract(%{
               type: :parent_call_event,
               notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
             })
  end

  test "rejects malformed childID values instead of inventing child session IDs" do
    malformed_values = [
      nil,
      "",
      "   ",
      42,
      :child_atom,
      ["child-list"],
      %{"id" => "child-map"}
    ]

    for malformed <- malformed_values do
      assert :ignore =
               ChildSessionCreationParser.extract(%{
                 type: :parent_call_event,
                 transport: :sse,
                 notification: %{
                   "method" => "notifications/progress",
                   "params" => %{"childID" => malformed, "seq" => 1}
                 }
               })
    end
  end
end
