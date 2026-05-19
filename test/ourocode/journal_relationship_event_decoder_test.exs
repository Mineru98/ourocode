defmodule Ourocode.JournalRelationshipEventDecoderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Journal.RelationshipEventDecoder
  alias Ourocode.Journal.RelationshipRecoveryRecord

  test "loads persisted parent call to child session relationship events as typed recovery records" do
    path = journal_path("relationship-load")

    Journal.append!(path, %{
      event_seq: 1,
      type: :parent_call_started,
      transport: :sse,
      parent_call_id: "parent-recovery-1",
      runtime_source: "opencode",
      external_ids: %{"session_id" => "session-recovery-1"},
      occurred_at_ms: 1,
      request_id: "call-recovery-1",
      method: "tools/call"
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :parent_call_event,
      transport: :sse,
      parent_call_id: "parent-recovery-1",
      runtime_source: "opencode",
      external_ids: %{"session_id" => "session-recovery-1"},
      occurred_at_ms: 2,
      request_id: "call-recovery-1",
      notification: %{
        "method" => "session/token",
        "params" => %{"childID" => "child-recovery-1", "seq" => 1, "token" => "hello"}
      },
      stream_cursor: %{"event_id" => "evt-2"}
    })

    Journal.append!(path, %{
      event_seq: 3,
      type: :child_pane_registered,
      pane_id: "child-pane:recovery-1",
      child_id: "child-recovery-1",
      parent_call_id: "parent-recovery-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"session_id" => "session-recovery-1"},
      stream_cursor: %{"event_id" => "evt-3"},
      pane_state: %{"title" => "Recovered child", "last_event_seq" => 2},
      created_at_ms: 3,
      updated_at_ms: 4,
      status: "working"
    })

    assert {:ok, records} = Journal.load_relationship_recovery_records(path)

    assert [
             %RelationshipRecoveryRecord{
               event_seq: 2,
               event_type: :parent_call_event,
               parent_call_id: "parent-recovery-1",
               child_id: "child-recovery-1",
               pane_id: "child-session:child-recovery-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "session-recovery-1", "childID" => "child-recovery-1"},
               stream_cursor: %{
                 "event_id" => "evt-2",
                 transport: :sse,
                 child_id: "child-recovery-1",
                 event_seq: 2
               },
               occurred_at_ms: 2,
               child_id_source: :childID,
               payload_path: :notification_params
             },
             %RelationshipRecoveryRecord{
               event_seq: 3,
               event_type: :child_pane_registered,
               parent_call_id: "parent-recovery-1",
               child_id: "child-recovery-1",
               pane_id: "child-pane:recovery-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "session-recovery-1", "childID" => "child-recovery-1"},
               stream_cursor: %{
                 "event_id" => "evt-3",
                 transport: :sse,
                 child_id: "child-recovery-1",
                 event_seq: 3
               },
               pane_state: %{"title" => "Recovered child", "last_event_seq" => 2},
               occurred_at_ms: 4,
               created_at_ms: 3,
               updated_at_ms: 4,
               status: :working,
               child_id_source: :pane_lifecycle,
               payload_path: :event
             }
           ] = records
  end

  test "decodes relationship events from restored string-key maps without touching unrelated entries" do
    entries = [
      %{"event_seq" => "1", "type" => "transport_started", "transport" => "stdio"},
      %{
        "event_seq" => "2",
        "type" => "parent_call_result",
        "transport" => "streamable_http",
        "parent_call_id" => "parent-http-recovery-1",
        "runtime_source" => "ouroboros",
        "external_ids" => %{"job_id" => "job-http-recovery-1"},
        "occurred_at_ms" => "10",
        "result" => %{"child_id" => "child-http-recovery-1"}
      }
    ]

    assert {:ok,
            [
              %RelationshipRecoveryRecord{
                event_seq: 2,
                event_type: :parent_call_result,
                parent_call_id: "parent-http-recovery-1",
                child_id: "child-http-recovery-1",
                pane_id: "child-session:child-http-recovery-1",
                runtime_source: "ouroboros",
                transport: :streamable_http,
                occurred_at_ms: 10,
                child_id_source: :child_id,
                payload_path: :result
              }
            ]} = RelationshipEventDecoder.decode_all(entries)
  end

  test "decodes explicitly acknowledged stream cursor without treating raw stream cursor as acknowledged" do
    entries = [
      %{
        event_seq: 1,
        type: :child_pane_updated,
        pane_id: "child-pane:ack-1",
        child_id: "child-ack-1",
        parent_call_id: "parent-ack-1",
        runtime_source: "codex",
        transport: :stdio,
        external_ids: %{"session_id" => "session-ack-1"},
        stream_cursor: %{"offset" => 99},
        acknowledged_stream_cursor: %{"offset" => 42, "source" => "pane-ack"},
        occurred_at_ms: 100
      },
      %{
        event_seq: 2,
        type: :child_pane_updated,
        pane_id: "child-pane:no-ack-1",
        child_id: "child-no-ack-1",
        parent_call_id: "parent-no-ack-1",
        runtime_source: "codex",
        transport: :stdio,
        external_ids: %{"session_id" => "session-no-ack-1"},
        stream_cursor: %{"offset" => 12},
        occurred_at_ms: 200
      }
    ]

    assert {:ok,
            [
              %RelationshipRecoveryRecord{
                acknowledged_stream_cursor: %{
                  "offset" => 42,
                  "source" => "pane-ack",
                  transport: :stdio,
                  child_id: "child-ack-1",
                  event_seq: 1
                }
              },
              %RelationshipRecoveryRecord{acknowledged_stream_cursor: nil}
            ]} = RelationshipEventDecoder.decode_all(entries)
  end

  defp journal_path(name) do
    path = Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")
    File.rm(path)
    path
  end
end
