defmodule Ourocode.Journal.RelationshipRecoveryFieldsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RelationshipRecoveryFields

  test "external_ids preserves existing ids and adds childID when absent" do
    assert RelationshipRecoveryFields.external_ids(
             %{external_ids: %{"session_id" => "session-1"}},
             "child-1"
           ) == %{"session_id" => "session-1", "childID" => "child-1"}

    assert RelationshipRecoveryFields.external_ids(
             %{external_ids: %{"childID" => "existing-child"}},
             "child-1"
           ) == %{"childID" => "existing-child"}
  end

  test "stream_cursor overlays transport child and event sequence" do
    assert RelationshipRecoveryFields.stream_cursor(
             %{stream_cursor: %{offset: 3}},
             :sse,
             7,
             "child-1"
           ) == %{offset: 3, transport: :sse, child_id: "child-1", event_seq: 7}
  end

  test "acknowledged_stream_cursor reads top-level and pane-state candidates" do
    assert RelationshipRecoveryFields.acknowledged_stream_cursor(
             %{last_acknowledged_stream_cursor: %{offset: 4}},
             :stdio,
             8,
             "child-2"
           ) == %{offset: 4, transport: :stdio, child_id: "child-2", event_seq: 8}

    assert RelationshipRecoveryFields.acknowledged_stream_cursor(
             %{pane_state: %{"acknowledged_stream_cursor" => %{"offset" => 5}}},
             :sse,
             9,
             "child-3"
           ) == %{"offset" => 5, transport: :sse, child_id: "child-3", event_seq: 9}

    assert RelationshipRecoveryFields.acknowledged_stream_cursor(%{}, :sse, 9, "child-3") == nil
  end

  test "pane_id prefers explicit ids then extracted key then child fallback" do
    assert RelationshipRecoveryFields.pane_id(%{pane_id: "pane-1"}, "child-1", "extracted") ==
             "pane-1"

    assert RelationshipRecoveryFields.pane_id(%{id: "pane-2"}, "child-1", "extracted") ==
             "pane-2"

    assert RelationshipRecoveryFields.pane_id(%{}, "child-1", "extracted") == "extracted"
    assert RelationshipRecoveryFields.pane_id(%{}, "child-1") == "child-session:child-1"
  end

  test "status normalizes working and completed state" do
    assert RelationshipRecoveryFields.status(%{status: "working"}, :child_pane_updated) ==
             :working

    assert RelationshipRecoveryFields.status(%{status: :completed}, :child_pane_updated) ==
             :completed

    assert RelationshipRecoveryFields.status(%{}, :child_pane_completed) == :completed
    assert RelationshipRecoveryFields.status(%{}, :child_pane_updated) == nil
  end
end
