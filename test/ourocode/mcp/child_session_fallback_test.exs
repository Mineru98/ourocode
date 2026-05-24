defmodule Ourocode.MCP.ChildSessionFallbackTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ChildSessionFallback

  test "derives fallback IDs for child session creation events from runtime IDs" do
    assert {:ok,
            %{
              child_id: "fallback:thread_id:thread-create-1",
              pane_key: "child-session:fallback:thread_id:thread-create-1",
              source: {:fallback, :thread_id},
              payload_path: :fallback_runtime_id
            }} =
             ChildSessionFallback.extract(%{
               type: :parent_call_started,
               parent_call_id: "parent-create-1",
               method: "agent/session/create",
               external_ids: %{
                 "session_id" => "session-create-1",
                 "thread_id" => "thread-create-1"
               }
             })
  end

  test "prefers lineage ID over nested input IDs" do
    assert {:ok,
            %{
              child_id: "fallback:lineage_id:lineage-1",
              source: {:fallback, :lineage_id}
            }} =
             ChildSessionFallback.extract(%{
               type: :parent_call_started,
               parent_call_id: "parent-lineage-1",
               method: "agent/session/create",
               params: %{
                 "lineageId" => " lineage-1 ",
                 "input" => %{
                   "sessionID" => "input-session-1",
                   "callID" => "input-call-1"
                 }
               }
             })
  end

  test "derives fallback IDs for stream events from stream payloads" do
    assert {:ok,
            %{
              child_id: "fallback:session_id:session-stream-1",
              source: {:fallback, :session_id}
            }} =
             ChildSessionFallback.extract(%{
               type: :parent_call_event,
               parent_call_id: "parent-stream-1",
               external_ids: %{"session_id" => "session-stream-1"},
               notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
             })
  end

  test "returns unresolved metadata for eligible stream events without runtime IDs" do
    assert {:unresolved,
            %{
              status: :unresolved,
              reason: :missing_fallback_runtime_metadata,
              parent_call_id: "parent-unresolved-1",
              checked_sources: checked_sources
            }} =
             ChildSessionFallback.extract(%{
               type: :parent_call_event,
               parent_call_id: "parent-unresolved-1",
               external_ids: %{"session_id" => " "},
               notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
             })

    assert checked_sources == ChildSessionFallback.runtime_id_sources()
  end

  test "ignores malformed explicit child IDs instead of inventing fallback IDs" do
    assert :ignore =
             ChildSessionFallback.extract(%{
               type: :parent_call_event,
               parent_call_id: "parent-malformed-1",
               external_ids: %{"session_id" => "session-1"},
               notification: %{"params" => %{"childID" => [], "seq" => 1}}
             })
  end

  test "ignores events that are not fallback eligible" do
    assert :ignore =
             ChildSessionFallback.extract(%{
               type: :parent_call_result,
               parent_call_id: "parent-result-1",
               external_ids: %{"session_id" => "session-1"}
             })
  end
end
