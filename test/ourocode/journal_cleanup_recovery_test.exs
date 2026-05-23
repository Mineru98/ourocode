defmodule Ourocode.JournalCleanupRecoveryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.Journal.CleanupRecoveryIndex
  alias Ourocode.Journal.CleanupRecoveryRecord

  test "loads completed session cleanup state from journal after restart" do
    path = journal_path("cleanup-recovery")

    Journal.append!(path, %{
      event_seq: 1,
      type: :child_pane_completed,
      pane_id: "child-pane:cleanup-1",
      child_id: "child-cleanup-1",
      parent_call_id: "parent-cleanup-1",
      runtime_source: "codex",
      transport: :stdio,
      external_ids: %{
        "session_id" => "session-cleanup-1",
        "thread_id" => "thread-cleanup-1"
      },
      stream_cursor: %{"offset" => 42},
      pane_state: %{"status" => "completed", "last_event_seq" => 7},
      occurred_at_ms: 10,
      status: "completed"
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :transport_cleanup,
      stream_kind: :transport,
      cleanup_reason: :idle_timeout,
      parent_call_id: "parent-cleanup-1",
      child_id: "child-cleanup-1",
      session_id: "session-cleanup-1",
      runtime_source: "codex",
      transport: :stdio,
      external_ids: %{
        "session_id" => "session-cleanup-1",
        "thread_id" => "thread-cleanup-1"
      },
      stream_cursor: %{"offset" => 42},
      stale_cleanup_timeout_ms: 30_000,
      stream_subscription_cleanup_timeout_ms: 10_000,
      cleanup_started_monotonic_ms: 500,
      released_resources: %{process_handles: 1, subscriptions: 2, ets_entries: 3},
      occurred_at_ms: 20
    })

    assert {:ok, records} = Journal.load_cleanup_recovery_records(path)

    assert [
             %CleanupRecoveryRecord{
               event_seq: 1,
               event_type: :child_pane_completed,
               cleanup_key: "child:child-cleanup-1",
               cleanup_state: :completed,
               child_id: "child-cleanup-1",
               session_id: "session-cleanup-1",
               pane_id: "child-pane:cleanup-1",
               replay_action: :noop
             },
             %CleanupRecoveryRecord{
               event_seq: 2,
               event_type: :transport_cleanup,
               cleanup_key: "child:child-cleanup-1",
               cleanup_state: :completed,
               cleanup_reason: :idle_timeout,
               stream_kind: :transport,
               released_resources: %{
                 "ets_entries" => 3,
                 "process_handles" => 1,
                 "subscriptions" => 2
               },
               replay_action: :noop
             }
           ] = records

    assert {:ok, index} = Journal.load_cleanup_recovery_index(path)
    assert %CleanupRecoveryIndex{event_seq_high_watermark: 2} = index

    assert {:ok,
            %{
              cleanup_key: "child:child-cleanup-1",
              cleanup_state: :completed,
              cleanup_reason: :idle_timeout,
              parent_call_id: "parent-cleanup-1",
              child_id: "child-cleanup-1",
              session_id: "session-cleanup-1",
              pane_id: "child-pane:cleanup-1",
              runtime_source: "codex",
              transport: :stdio,
              stream_cursor: %{"offset" => 42},
              pane_state: %{"status" => "completed", "last_event_seq" => 7},
              released_resources: %{
                "ets_entries" => 3,
                "process_handles" => 1,
                "subscriptions" => 2
              },
              stale_cleanup_timeout_ms: 30_000,
              stream_subscription_cleanup_timeout_ms: 10_000,
              cleanup_started_monotonic_ms: 500,
              replay_action: :noop,
              event_seqs: [1, 2],
              source_event_types: [:child_pane_completed, :transport_cleanup],
              latest_event_seq: 2
            }} = CleanupRecoveryIndex.child(index, "child-cleanup-1")

    assert {:ok, [parent_cleanup]} = CleanupRecoveryIndex.parent(index, "parent-cleanup-1")
    assert parent_cleanup.cleanup_key == "child:child-cleanup-1"

    assert {:ok, session_cleanup} = CleanupRecoveryIndex.session(index, "session-cleanup-1")
    assert session_cleanup.cleanup_key == "child:child-cleanup-1"

    assert {:ok, pane_cleanup} = CleanupRecoveryIndex.pane(index, "child-pane:cleanup-1")
    assert pane_cleanup.cleanup_key == "child:child-cleanup-1"
  end

  test "completed cleanup replay is idempotent after restart" do
    records = [
      record(
        event_seq: 1,
        cleanup_key: "child:idempotent-1",
        child_id: "idempotent-1",
        parent_call_id: "parent-idempotent-1",
        replay_action: :release_runtime_resources,
        released_resources: %{}
      ),
      record(
        event_seq: 2,
        event_type: :stream_cleanup,
        cleanup_key: "child:idempotent-1",
        cleanup_reason: :idle_timeout,
        child_id: "idempotent-1",
        parent_call_id: "parent-idempotent-1",
        replay_action: :noop,
        released_resources: %{subscriptions: 1}
      )
    ]

    assert {:ok, index} = CleanupRecoveryIndex.build(records)

    assert {:ok,
            %{
              cleanup_key: "child:idempotent-1",
              cleanup_state: :completed,
              replay_action: :noop,
              idempotent?: true,
              latest_event_seq: 2
            }} = CleanupRecoveryIndex.replay_verdict(index, "child:idempotent-1")

    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index, "child:idempotent-1")
    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index, "child:idempotent-1")
  end

  test "journal recovery reconstructs cancelled cleanup state as idempotent after restart" do
    path = journal_path("cancelled-cleanup-recovery")

    Journal.append!(path, %{
      event_seq: 1,
      type: :child_pane_cancelled,
      pane_id: "child-pane:cancelled-1",
      child_id: "child-cancelled-1",
      parent_call_id: "parent-cancelled-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{
        "session_id" => "session-cancelled-1",
        "childID" => "child-cancelled-1",
        "thread_id" => "thread-cancelled-1"
      },
      stream_cursor: %{"event_seq" => 12, "offset" => 4096},
      pane_state: %{
        "status" => "cancelled",
        "open?" => false,
        "focused?" => false,
        "last_event_seq" => 12
      },
      status: "cancelled",
      occurred_at_ms: 100
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :stream_cleanup,
      stream_kind: :session,
      cleanup_reason: :cancelled,
      parent_call_id: "parent-cancelled-1",
      child_id: "child-cancelled-1",
      session_id: "session-cancelled-1",
      pane_id: "child-pane:cancelled-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{
        "session_id" => "session-cancelled-1",
        "childID" => "child-cancelled-1",
        "thread_id" => "thread-cancelled-1"
      },
      stream_cursor: %{"event_seq" => 12, "offset" => 4096},
      pane_state: %{
        "status" => "cancelled",
        "open?" => false,
        "focused?" => false,
        "last_event_seq" => 12
      },
      stale_cleanup_timeout_ms: 30_000,
      stream_subscription_cleanup_timeout_ms: 10_000,
      cleanup_started_monotonic_ms: 900,
      cleanup_action: :release_runtime_resources,
      released_resources: %{
        process_handles: 1,
        subscriptions: 1,
        registered_buffers: 1,
        ets_entries: 2,
        pending_events: 0
      },
      idempotency_key: "session:session-cancelled-1",
      occurred_at_ms: 110
    })

    assert {:ok, index} = Journal.load_cleanup_recovery_index(path)

    assert {:ok,
            %{
              cleanup_key: "session:session-cancelled-1",
              cleanup_state: :completed,
              cleanup_reason: :cancelled,
              child_id: "child-cancelled-1",
              session_id: "session-cancelled-1",
              pane_id: "child-pane:cancelled-1",
              runtime_source: "opencode",
              transport: :sse,
              stream_cursor: %{"event_seq" => 12, "offset" => 4096},
              pane_state: %{
                "status" => "cancelled",
                "open?" => false,
                "focused?" => false,
                "last_event_seq" => 12
              },
              released_resources: %{
                "ets_entries" => 2,
                "pending_events" => 0,
                "process_handles" => 1,
                "registered_buffers" => 1,
                "subscriptions" => 1
              },
              replay_action: :noop,
              event_seqs: [2],
              source_event_types: [:stream_cleanup],
              latest_event_seq: 2
            }} = CleanupRecoveryIndex.session(index, "session-cancelled-1")

    assert {:ok,
            %{
              cleanup_key: "session:session-cancelled-1",
              cleanup_state: :completed,
              cleanup_reason: :cancelled,
              replay_action: :noop
            }} = CleanupRecoveryIndex.child(index, "child-cancelled-1")

    assert {:ok,
            %{
              cleanup_key: "child:child-cancelled-1",
              cleanup_state: :completed,
              pane_state: %{"status" => "cancelled"},
              replay_action: :noop,
              source_event_types: [:child_pane_cancelled]
            }} = CleanupRecoveryIndex.cleanup(index, "child:child-cancelled-1")

    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index)
    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index)

    assert :ok =
             CleanupRecoveryIndex.verify_idempotent_replay(index, "session:session-cancelled-1")

    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index, "child:child-cancelled-1")
  end

  test "journal recovery reconstructs failed session cleanup as idempotent after restart" do
    path = journal_path("failed-session-cleanup-recovery")

    Journal.append!(path, %{
      event_seq: 1,
      type: :parent_call_failed,
      parent_call_id: "parent-failed-1",
      child_id: "child-failed-1",
      session_id: "session-failed-1",
      pane_id: "child-pane:failed-1",
      runtime_source: "codex",
      transport: :streamable_http,
      external_ids: %{
        "session_id" => "session-failed-1",
        "thread_id" => "thread-failed-1",
        "native_session_id" => "native-failed-1"
      },
      stream_cursor: %{"event_seq" => 19, "offset" => 8192},
      pane_state: %{
        "status" => "failed",
        "open?" => true,
        "focused?" => true,
        "last_event_seq" => 19
      },
      replay_action: :release_runtime_resources,
      idempotency_key: "session:session-failed-1",
      error: %{"message" => "runtime child failed"},
      occurred_at_ms: 200
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :stream_cleanup,
      stream_kind: :session,
      cleanup_reason: :operation_timeout,
      parent_call_id: "parent-failed-1",
      child_id: "child-failed-1",
      session_id: "session-failed-1",
      pane_id: "child-pane:failed-1",
      runtime_source: "codex",
      transport: :streamable_http,
      external_ids: %{
        "session_id" => "session-failed-1",
        "thread_id" => "thread-failed-1",
        "native_session_id" => "native-failed-1"
      },
      stream_cursor: %{"event_seq" => 19, "offset" => 8192},
      pane_state: %{
        "status" => "failed",
        "open?" => false,
        "focused?" => false,
        "last_event_seq" => 19
      },
      stale_cleanup_timeout_ms: 45_000,
      stream_subscription_cleanup_timeout_ms: 15_000,
      cleanup_started_monotonic_ms: 1_200,
      cleanup_action: :release_runtime_resources,
      released_resources: %{
        process_handles: 1,
        subscriptions: 1,
        registered_buffers: 1,
        ets_entries: 2,
        pending_events: 0
      },
      idempotency_key: "session:session-failed-1",
      occurred_at_ms: 220
    })

    assert {:ok, records} = Journal.load_cleanup_recovery_records(path)

    assert [
             %CleanupRecoveryRecord{
               event_seq: 1,
               event_type: :parent_call_failed,
               cleanup_key: "session:session-failed-1",
               cleanup_state: :pending,
               replay_action: :release_runtime_resources
             },
             %CleanupRecoveryRecord{
               event_seq: 2,
               event_type: :stream_cleanup,
               cleanup_key: "session:session-failed-1",
               cleanup_state: :completed,
               cleanup_reason: :operation_timeout,
               replay_action: :noop
             }
           ] = records

    assert {:ok, index} = Journal.load_cleanup_recovery_index(path)

    assert {:ok,
            %{
              cleanup_key: "session:session-failed-1",
              cleanup_state: :completed,
              cleanup_reason: :operation_timeout,
              child_id: "child-failed-1",
              session_id: "session-failed-1",
              pane_id: "child-pane:failed-1",
              runtime_source: "codex",
              transport: :streamable_http,
              stream_cursor: %{"event_seq" => 19, "offset" => 8192},
              pane_state: %{
                "status" => "failed",
                "open?" => false,
                "focused?" => false,
                "last_event_seq" => 19
              },
              released_resources: %{
                "ets_entries" => 2,
                "pending_events" => 0,
                "process_handles" => 1,
                "registered_buffers" => 1,
                "subscriptions" => 1
              },
              stale_cleanup_timeout_ms: 45_000,
              stream_subscription_cleanup_timeout_ms: 15_000,
              cleanup_started_monotonic_ms: 1_200,
              replay_action: :noop,
              event_seqs: [1, 2],
              source_event_types: [:parent_call_failed, :stream_cleanup],
              latest_event_seq: 2
            }} = CleanupRecoveryIndex.session(index, "session-failed-1")

    assert {:ok,
            %{
              cleanup_key: "session:session-failed-1",
              idempotent?: true,
              replay_action: :noop,
              cleanup_state: :completed,
              latest_event_seq: 2
            }} = CleanupRecoveryIndex.replay_verdict(index, "session:session-failed-1")

    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index)
    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(index, "session:session-failed-1")
  end

  test "journal recovery reconstructs orphaned session cleanup and makes replay idempotent after cleanup" do
    path = journal_path("orphaned-session-cleanup-recovery")

    Journal.append!(path, %{
      event_seq: 1,
      type: :child_pane_registered,
      pane_id: "child-pane:orphaned-1",
      child_id: "child-orphaned-1",
      parent_call_id: "parent-orphaned-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{
        "session_id" => "session-orphaned-1",
        "childID" => "child-orphaned-1",
        "input.sessionID" => "input-session-orphaned-1",
        "input.callID" => "input-call-orphaned-1"
      },
      stream_cursor: %{"event_seq" => 1, "offset" => 256},
      pane_state: %{
        "status" => "working",
        "open?" => true,
        "focused?" => true,
        "last_event_seq" => 1
      },
      status: "working",
      occurred_at_ms: 100
    })

    Journal.append!(path, %{
      event_seq: 2,
      type: :child_pane_updated,
      pane_id: "child-pane:orphaned-1",
      child_id: "child-orphaned-1",
      parent_call_id: "parent-orphaned-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{
        "session_id" => "session-orphaned-1",
        "childID" => "child-orphaned-1",
        "input.sessionID" => "input-session-orphaned-1",
        "input.callID" => "input-call-orphaned-1"
      },
      stream_cursor: %{"event_seq" => 7, "offset" => 2048},
      pane_state: %{
        "status" => "working",
        "open?" => true,
        "focused?" => false,
        "last_event_seq" => 7
      },
      status: "working",
      occurred_at_ms: 120
    })

    assert {:ok, orphan_index} = Journal.load_cleanup_recovery_index(path)

    assert {:ok,
            %{
              cleanup_key: "session:session-orphaned-1",
              cleanup_state: :pending,
              child_id: "child-orphaned-1",
              session_id: "session-orphaned-1",
              pane_id: "child-pane:orphaned-1",
              runtime_source: "opencode",
              transport: :sse,
              stream_cursor: %{"event_seq" => 7, "offset" => 2048},
              pane_state: %{
                "status" => "working",
                "open?" => true,
                "focused?" => false,
                "last_event_seq" => 7
              },
              replay_action: :release_runtime_resources,
              event_seqs: [1, 2],
              source_event_types: [:child_pane_registered, :child_pane_updated],
              latest_event_seq: 2
            }} = CleanupRecoveryIndex.session(orphan_index, "session-orphaned-1")

    assert {:ok,
            %{
              cleanup_key: "session:session-orphaned-1",
              cleanup_state: :pending,
              replay_action: :release_runtime_resources,
              idempotent?: false
            }} = CleanupRecoveryIndex.replay_verdict(orphan_index, "session:session-orphaned-1")

    assert {:error,
            {:cleanup_replay_not_idempotent,
             %{
               cleanup_key: "session:session-orphaned-1",
               cleanup_state: :pending,
               replay_action: :release_runtime_resources,
               idempotent?: false
             }}} = CleanupRecoveryIndex.verify_idempotent_replay(orphan_index)

    Journal.append!(path, %{
      event_seq: 3,
      type: :stream_cleanup,
      stream_kind: :session,
      cleanup_reason: :idle_timeout,
      parent_call_id: "parent-orphaned-1",
      child_id: "child-orphaned-1",
      session_id: "session-orphaned-1",
      pane_id: "child-pane:orphaned-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{
        "session_id" => "session-orphaned-1",
        "childID" => "child-orphaned-1",
        "input.sessionID" => "input-session-orphaned-1",
        "input.callID" => "input-call-orphaned-1"
      },
      stream_cursor: %{"event_seq" => 7, "offset" => 2048},
      pane_state: %{
        "status" => "working",
        "open?" => false,
        "focused?" => false,
        "last_event_seq" => 7
      },
      stale_cleanup_timeout_ms: 30_000,
      stream_subscription_cleanup_timeout_ms: 10_000,
      cleanup_started_monotonic_ms: 1_500,
      released_resources: %{
        process_handles: 1,
        subscriptions: 1,
        registered_buffers: 1,
        ets_entries: 2,
        pending_events: 0
      },
      idempotency_key: "session:session-orphaned-1",
      occurred_at_ms: 160
    })

    assert {:ok, recovered_index} = Journal.load_cleanup_recovery_index(path)

    assert {:ok,
            %{
              cleanup_key: "session:session-orphaned-1",
              cleanup_state: :completed,
              cleanup_reason: :idle_timeout,
              child_id: "child-orphaned-1",
              session_id: "session-orphaned-1",
              pane_id: "child-pane:orphaned-1",
              stream_cursor: %{"event_seq" => 7, "offset" => 2048},
              pane_state: %{
                "status" => "working",
                "open?" => false,
                "focused?" => false,
                "last_event_seq" => 7
              },
              released_resources: %{
                "ets_entries" => 2,
                "pending_events" => 0,
                "process_handles" => 1,
                "registered_buffers" => 1,
                "subscriptions" => 1
              },
              replay_action: :noop,
              event_seqs: [1, 2, 3],
              source_event_types: [
                :child_pane_registered,
                :child_pane_updated,
                :stream_cleanup
              ],
              latest_event_seq: 3
            }} = CleanupRecoveryIndex.child(recovered_index, "child-orphaned-1")

    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(recovered_index)
    assert :ok = CleanupRecoveryIndex.verify_idempotent_replay(recovered_index)

    assert :ok =
             CleanupRecoveryIndex.verify_idempotent_replay(
               recovered_index,
               "session:session-orphaned-1"
             )
  end

  test "unresolved failed session cleanup is not considered idempotent after restart" do
    path = journal_path("unresolved-failed-session-cleanup")

    Journal.append!(path, %{
      event_seq: 1,
      type: :transport_failed,
      parent_call_id: "parent-unresolved-failed-1",
      child_id: "child-unresolved-failed-1",
      runtime_source: "ouroboros",
      transport: :sse,
      external_ids: %{"session_id" => "session-unresolved-failed-1"},
      stream_cursor: %{"event_seq" => 4},
      replay_action: :release_runtime_resources,
      idempotency_key: "session:session-unresolved-failed-1",
      error: %{"message" => "transport crashed before cleanup"},
      occurred_at_ms: 300
    })

    assert {:ok, index} = Journal.load_cleanup_recovery_index(path)

    assert {:ok,
            %{
              cleanup_key: "session:session-unresolved-failed-1",
              cleanup_state: :pending,
              replay_action: :release_runtime_resources,
              idempotent?: false
            }} = CleanupRecoveryIndex.replay_verdict(index, "session:session-unresolved-failed-1")

    assert {:error,
            {:cleanup_replay_not_idempotent,
             %{
               cleanup_key: "session:session-unresolved-failed-1",
               cleanup_state: :pending,
               replay_action: :release_runtime_resources,
               idempotent?: false
             }}} = CleanupRecoveryIndex.verify_idempotent_replay(index)
  end

  test "unknown cleanup replay keys are not treated as idempotent" do
    assert {:ok, index} = CleanupRecoveryIndex.build([])

    assert {:error, :not_recovered} =
             CleanupRecoveryIndex.replay_verdict(index, "child:not-recovered")

    assert {:error, :not_recovered} =
             CleanupRecoveryIndex.verify_idempotent_replay(index, "child:not-recovered")
  end

  defp record(attrs) do
    defaults = [
      event_seq: 1,
      event_type: :child_pane_completed,
      cleanup_key: "child:default",
      cleanup_state: :completed,
      runtime_source: "synthetic",
      external_ids: %{},
      stream_cursor: %{},
      released_resources: %{},
      idempotency_key: Keyword.get(attrs, :cleanup_key, "child:default"),
      replay_action: :noop,
      occurred_at_ms: 1
    ]

    struct!(CleanupRecoveryRecord, Keyword.merge(defaults, attrs))
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
