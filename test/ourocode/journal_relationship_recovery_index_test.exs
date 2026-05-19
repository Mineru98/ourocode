defmodule Ourocode.JournalRelationshipRecoveryIndexTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Journal.RelationshipRecoveryIndex
  alias Ourocode.Journal.RelationshipRecoveryRecord

  test "builds parent MCP call to child session mappings from decoded records" do
    records = [
      record(
        event_seq: 2,
        event_type: :parent_call_event,
        parent_call_id: "parent-index-1",
        child_id: "child-index-a",
        pane_id: "child-session:child-index-a",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{"session_id" => "session-index-1", "childID" => "child-index-a"},
        stream_cursor: %{"event_id" => "evt-2", event_seq: 2},
        pane_state: %{"last_event_seq" => 2},
        occurred_at_ms: 20
      ),
      record(
        event_seq: 3,
        event_type: :child_pane_registered,
        parent_call_id: "parent-index-1",
        child_id: "child-index-a",
        pane_id: "child-pane:index-a",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{"session_id" => "session-index-1", "thread_id" => "thread-index-1"},
        stream_cursor: %{"event_id" => "evt-3", event_seq: 3},
        pane_state: %{"title" => "Recovered A", "last_event_seq" => 3},
        occurred_at_ms: 30,
        created_at_ms: 25,
        updated_at_ms: 35,
        status: :working
      ),
      record(
        event_seq: 4,
        event_type: :parent_call_event,
        parent_call_id: "parent-index-1",
        child_id: "child-index-b",
        pane_id: "child-session:child-index-b",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{"session_id" => "session-index-1", "childID" => "child-index-b"},
        stream_cursor: %{"event_id" => "evt-4", event_seq: 4},
        pane_state: %{"last_event_seq" => 4},
        occurred_at_ms: 40
      )
    ]

    assert {:ok, index} = RelationshipRecoveryIndex.build(records)

    assert %RelationshipRecoveryIndex{event_seq_high_watermark: 4} = index

    assert {:ok,
            %{
              parent_call_id: "parent-index-1",
              runtime_source: "opencode",
              transport: :sse,
              child_ids: ["child-index-a", "child-index-b"],
              latest_event_seq: 4,
              children: [child_a, child_b]
            }} = RelationshipRecoveryIndex.parent(index, "parent-index-1")

    assert %{
             parent_call_id: "parent-index-1",
             child_id: "child-index-a",
             pane_id: "child-pane:index-a",
             external_ids: %{
               "childID" => "child-index-a",
               "session_id" => "session-index-1",
               "thread_id" => "thread-index-1"
             },
             stream_cursor: %{"event_id" => "evt-3", event_seq: 3},
             pane_state: %{"title" => "Recovered A", "last_event_seq" => 3},
             status: :working,
             first_event_seq: 2,
             latest_event_seq: 3,
             event_seqs: [2, 3],
             source_event_types: [:parent_call_event, :child_pane_registered],
             occurred_at_ms: 30,
             created_at_ms: 25,
             updated_at_ms: 35
           } = child_a

    assert %{child_id: "child-index-b", latest_event_seq: 4, event_seqs: [4]} = child_b
    assert {:ok, [^child_a]} = RelationshipRecoveryIndex.child(index, "child-index-a")
    assert {:ok, ^child_a} = RelationshipRecoveryIndex.pane(index, "child-pane:index-a")
  end

  test "loads persisted relationship records and reconstructs the recovery index" do
    path = journal_path("relationship-index")

    Journal.append!(path, %{
      event_seq: 1,
      type: :parent_call_event,
      transport: :stdio,
      parent_call_id: "parent-journal-index-1",
      runtime_source: "codex",
      external_ids: %{"thread_id" => "thread-journal-index-1"},
      occurred_at_ms: 1,
      notification: %{"params" => %{"childID" => "child-journal-index-1", "seq" => 1}},
      stream_cursor: %{"offset" => 12}
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :child_pane_completed,
      pane_id: "child-pane:journal-index-1",
      child_id: "child-journal-index-1",
      parent_call_id: "parent-journal-index-1",
      runtime_source: "codex",
      transport: :stdio,
      external_ids: %{"thread_id" => "thread-journal-index-1"},
      stream_cursor: %{"offset" => 42},
      pane_state: %{"last_event_seq" => 2},
      occurred_at_ms: 2,
      status: "completed"
    })

    assert {:ok, index} = Journal.load_relationship_recovery_index(path)

    assert {:ok,
            %{
              child_ids: ["child-journal-index-1"],
              status: :completed,
              children: [
                %{
                  pane_id: "child-pane:journal-index-1",
                  status: :completed,
                  stream_cursor: %{
                    "offset" => 42,
                    transport: :stdio,
                    child_id: "child-journal-index-1",
                    event_seq: 2
                  }
                }
              ]
            }} = RelationshipRecoveryIndex.parent(index, "parent-journal-index-1")
  end

  test "recovers last acknowledged stream cursors independently for each pane and child session" do
    path = journal_path("acknowledged-cursor-index")

    Journal.append!(path, %{
      event_seq: 1,
      type: :child_pane_updated,
      pane_id: "child-pane:ack-a",
      child_id: "child-ack-a",
      parent_call_id: "parent-ack-index-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"session_id" => "session-ack-a"},
      stream_cursor: %{"event_id" => "evt-a-raw"},
      acknowledged_stream_cursor: %{"event_id" => "evt-a-ack", "offset" => 10},
      pane_state: %{"last_event_seq" => 1},
      occurred_at_ms: 1,
      status: "working"
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :child_pane_updated,
      pane_id: "child-pane:ack-b",
      child_id: "child-ack-b",
      parent_call_id: "parent-ack-index-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"session_id" => "session-ack-b"},
      stream_cursor: %{"event_id" => "evt-b-raw"},
      acknowledged_stream_cursor: %{"event_id" => "evt-b-ack", "offset" => 20},
      pane_state: %{"last_event_seq" => 2},
      occurred_at_ms: 2,
      status: "working"
    })

    Journal.append!(path, %{
      event_seq: 3,
      type: :child_pane_updated,
      pane_id: "child-pane:ack-a",
      child_id: "child-ack-a",
      parent_call_id: "parent-ack-index-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"session_id" => "session-ack-a"},
      stream_cursor: %{"event_id" => "evt-a-raw-later"},
      pane_state: %{
        "last_event_seq" => 3,
        "last_acknowledged_stream_cursor" => %{"event_id" => "evt-a-ack-later", "offset" => 30}
      },
      occurred_at_ms: 3,
      status: "working"
    })

    assert {:ok, index} = Journal.load_relationship_recovery_index(path)

    assert {:ok,
            %{
              "event_id" => "evt-a-ack-later",
              "offset" => 30,
              transport: :sse,
              child_id: "child-ack-a",
              event_seq: 3
            }} = RelationshipRecoveryIndex.acknowledged_stream_cursor_for_pane(index, "child-pane:ack-a")

    assert {:ok,
            %{
              "event_id" => "evt-b-ack",
              "offset" => 20,
              transport: :sse,
              child_id: "child-ack-b",
              event_seq: 2
            }} = RelationshipRecoveryIndex.acknowledged_stream_cursor_for_pane(index, "child-pane:ack-b")

    assert {:ok,
            %{"event_id" => "evt-a-ack-later", "offset" => 30}} =
             RelationshipRecoveryIndex.acknowledged_stream_cursor_for_child(index, "child-ack-a")

    assert {:ok,
            %{"event_id" => "evt-b-ack", "offset" => 20}} =
             RelationshipRecoveryIndex.acknowledged_stream_cursor_for_child(index, "child-ack-b")
  end

  test "rejects non decoded recovery records" do
    assert {:error, :invalid_relationship_recovery_record} =
             RelationshipRecoveryIndex.build([%{parent_call_id: "parent-invalid"}])
  end

  defp record(attrs) do
    defaults = [
      event_seq: 1,
      event_type: :parent_call_event,
      parent_call_id: "parent-default",
      child_id: "child-default",
      pane_id: "child-session:child-default",
      runtime_source: "ouroboros",
      transport: :stdio,
      external_ids: %{"childID" => "child-default"},
      stream_cursor: %{event_seq: 1, child_id: "child-default"},
      pane_state: %{},
      occurred_at_ms: 1
    ]

    struct!(RelationshipRecoveryRecord, Keyword.merge(defaults, attrs))
  end

  defp journal_path(name) do
    path = Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")
    File.rm(path)
    path
  end
end
