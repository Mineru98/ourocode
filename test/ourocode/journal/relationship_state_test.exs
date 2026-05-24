defmodule Ourocode.Journal.RelationshipStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RelationshipRecoveryRecord
  alias Ourocode.Journal.RelationshipState

  test "from_record converts a decoded recovery record into mergeable state" do
    record = record(event_seq: 5, event_type: :child_pane_registered)

    assert {:ok,
            %{
              parent_call_id: "parent-1",
              child_id: "child-1",
              pane_id: "pane-1",
              first_event_seq: 5,
              latest_event_seq: 5,
              event_seqs: [5],
              source_event_types: [:child_pane_registered]
            }} = RelationshipState.from_record(record)
  end

  test "from_record rejects non decoded records" do
    assert RelationshipState.from_record(%{parent_call_id: "parent-1"}) ==
             {:error, :invalid_relationship_recovery_record}
  end

  test "merge advances cursors status timestamps and pane state" do
    existing =
      state(
        event_seq: 2,
        pane_id: "pane-old",
        external_ids: %{"session_id" => "session-1"},
        stream_cursor: %{event_seq: 2, offset: 1},
        pane_state: %{stream_entries: [%{child_event_id: "event-1", token: "old"}]},
        occurred_at_ms: 20,
        created_at_ms: 15,
        updated_at_ms: 21
      )

    incoming =
      state(
        event_seq: 4,
        event_type: :child_pane_completed,
        pane_id: "pane-new",
        external_ids: %{"thread_id" => "thread-1"},
        stream_cursor: %{event_seq: 4, offset: 2},
        acknowledged_stream_cursor: %{event_seq: 4, offset: 2},
        pane_state: %{stream_entries: [%{child_event_id: "event-1", token: "new"}], title: "Done"},
        status: :completed,
        occurred_at_ms: 40,
        created_at_ms: 30,
        updated_at_ms: 50
      )

    assert %{
             pane_id: "pane-new",
             external_ids: %{"session_id" => "session-1", "thread_id" => "thread-1"},
             stream_cursor: %{event_seq: 4, offset: 2},
             acknowledged_stream_cursor: %{event_seq: 4, offset: 2},
             pane_state: %{
               stream_entries: [%{child_event_id: "event-1", token: "old"}],
               title: "Done"
             },
             status: :completed,
             latest_event_seq: 4,
             event_seqs: [2, 4],
             source_event_types: [:parent_call_event, :child_pane_completed],
             occurred_at_ms: 40,
             created_at_ms: 15,
             updated_at_ms: 50
           } = RelationshipState.merge(existing, incoming)
  end

  defp state(attrs) do
    attrs
    |> record()
    |> RelationshipState.from_record()
    |> elem(1)
  end

  defp record(attrs) do
    defaults = [
      event_seq: 1,
      event_type: :parent_call_event,
      parent_call_id: "parent-1",
      child_id: "child-1",
      pane_id: "pane-1",
      runtime_source: "synthetic",
      transport: :sse,
      external_ids: %{"childID" => "child-1"},
      stream_cursor: %{event_seq: 1},
      pane_state: %{},
      occurred_at_ms: 10
    ]

    struct!(RelationshipRecoveryRecord, Keyword.merge(defaults, attrs))
  end
end
