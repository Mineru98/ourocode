defmodule Ourocode.Journal.CleanupStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.CleanupState

  test "completed cleanup and noop replay action dominate pending release state" do
    merged =
      CleanupState.merge(
        cleanup_state(cleanup_state: :pending, replay_action: :release_runtime_resources),
        cleanup_state(
          cleanup_state: :completed,
          replay_action: :noop,
          cleanup_reason: :stream_closed,
          latest_event_seq: 3,
          event_seqs: [3],
          source_event_types: [:transport_cleanup]
        )
      )

    assert merged.cleanup_state == :completed
    assert merged.replay_action == :noop
    assert merged.cleanup_reason == :stream_closed
    assert merged.latest_event_seq == 3
    assert merged.event_seqs == [1, 3]
    assert merged.source_event_types == [:transport_failed, :transport_cleanup]
  end

  test "merges identifiers, cursors, pane state, and latest monotonic timestamps" do
    merged =
      CleanupState.merge(
        cleanup_state(
          external_ids: %{"session_id" => "session-1"},
          stream_cursor: %{"offset" => 1},
          pane_state: %{"status" => "closing"},
          cleanup_started_monotonic_ms: 10
        ),
        cleanup_state(
          child_id: "child-1",
          pane_id: "child-pane:1",
          external_ids: %{"job_id" => "job-1"},
          stream_cursor: %{"offset" => 2, "event_id" => "evt-2"},
          pane_state: %{"status" => "closed", "last_event_seq" => 2},
          cleanup_started_monotonic_ms: 20
        )
      )

    assert merged.child_id == "child-1"
    assert merged.pane_id == "child-pane:1"
    assert merged.external_ids == %{"session_id" => "session-1", "job_id" => "job-1"}
    assert merged.stream_cursor == %{"offset" => 2, "event_id" => "evt-2"}
    assert merged.pane_state == %{"status" => "closed", "last_event_seq" => 2}
    assert merged.cleanup_started_monotonic_ms == 20
  end

  test "merges resource counts by keeping the strongest integer evidence" do
    assert CleanupState.merge_resource_counts(
             %{"processes" => 1, "subscriptions" => 4, "note" => "old"},
             %{"processes" => 3, "subscriptions" => 2, "note" => "new"}
           ) == %{
             "processes" => 3,
             "subscriptions" => 4,
             "note" => "new"
           }
  end

  test "cleanup_key prefers explicit idempotency key" do
    event = %{idempotency_key: "cleanup-id-1", child_id: "child-1", session_id: "session-1"}

    assert CleanupState.cleanup_key(event, :prefer_child) == {:ok, "cleanup-id-1"}
    assert CleanupState.idempotency_key(event, "child:child-1") == "cleanup-id-1"
  end

  test "cleanup_key derives stable identities by preference" do
    assert CleanupState.cleanup_key(
             %{child_id: "child-1", session_id: "session-1"},
             :prefer_child
           ) ==
             {:ok, "child:child-1"}

    assert CleanupState.cleanup_key(
             %{child_id: "child-1", session_id: "session-1"},
             :prefer_session
           ) ==
             {:ok, "session:session-1"}

    assert CleanupState.cleanup_key(%{parent_call_id: "parent-1", transport: :sse}, :prefer_child) ==
             {:ok, "transport:sse:parent-1"}

    assert CleanupState.cleanup_key(%{}, :prefer_child) == {:error, :missing_cleanup_identity}
  end

  test "replay_action allows only known recovery actions" do
    assert CleanupState.replay_action(%{replay_action: :noop}, :release_runtime_resources) ==
             :noop

    assert CleanupState.replay_action(%{replay_action: "noop"}, :release_runtime_resources) ==
             :noop

    assert CleanupState.replay_action(%{replay_action: :unknown}, :release_runtime_resources) ==
             :release_runtime_resources
  end

  defp cleanup_state(overrides) do
    Map.merge(
      %{
        cleanup_key: "child:child-1",
        cleanup_state: :pending,
        cleanup_reason: nil,
        stream_kind: :child,
        parent_call_id: "parent-1",
        child_id: nil,
        session_id: nil,
        pane_id: nil,
        runtime_source: "synthetic",
        transport: :sse,
        external_ids: %{},
        stream_cursor: %{},
        pane_state: %{},
        released_resources: %{},
        stale_cleanup_timeout_ms: nil,
        stream_subscription_cleanup_timeout_ms: nil,
        cleanup_started_monotonic_ms: nil,
        idempotency_key: "idempotency-1",
        replay_action: :release_runtime_resources,
        first_event_seq: 1,
        latest_event_seq: 1,
        event_seqs: [1],
        source_event_types: [:transport_failed],
        occurred_at_ms: 1
      },
      Map.new(overrides)
    )
  end
end
