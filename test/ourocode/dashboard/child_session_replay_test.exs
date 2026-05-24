defmodule Ourocode.Dashboard.ChildSessionReplayTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionReplay

  test "builds pane lifecycle events from recovered relationships" do
    relationship = %{
      status: :completed,
      pane_id: "child-session:alpha",
      child_id: "alpha",
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :sse,
      external_ids: %{"childID" => "alpha"},
      stream_cursor: %{event_seq: 4},
      latest_event_seq: 4,
      acknowledged_stream_cursor: %{event_seq: 3},
      pane_state: %{stream_entries: [%{event_seq: 4, token: "done"}]},
      created_at_ms: 1,
      updated_at_ms: nil,
      occurred_at_ms: 5
    }

    assert ChildSessionReplay.relationship_pane_event(relationship) == %{
             type: :child_pane_completed,
             pane_id: "child-session:alpha",
             child_id: "alpha",
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             transport: :sse,
             external_ids: %{"childID" => "alpha"},
             stream_cursor: %{event_seq: 4},
             pane_state: %{
               last_event_seq: 4,
               last_acknowledged_stream_cursor: %{event_seq: 3},
               stream_entries: [%{event_seq: 4, token: "done"}]
             },
             created_at_ms: 1,
             updated_at_ms: 5,
             occurred_at_ms: 5,
             status: :completed
           }
  end

  test "drops stream entries already present in existing pane replay state" do
    event = %{
      pane_state: %{
        stream_entries: [
          %{event_seq: 1, runtime_seq: 1, token: "alpha"},
          %{"event_seq" => 2, "runtime_seq" => 2, "token" => "beta"}
        ]
      }
    }

    existing_entries = [
      %{event_seq: 1, runtime_seq: 1, token: "alpha"},
      %{event_seq: 2, runtime_seq: 2, token: "beta"}
    ]

    assert ChildSessionReplay.drop_replayed_stream_entries(event, existing_entries) == %{
             pane_state: %{}
           }
  end

  test "detects acknowledged replay and surfaces cursor gaps" do
    existing_pane = %{
      pane_state: %{last_acknowledged_stream_cursor: %{event_seq: 2, event_id: "evt-2"}}
    }

    assert ChildSessionReplay.replayed_at_or_before_acknowledged_cursor?(
             %{stream_cursor: %{event_seq: 2}},
             existing_pane
           )

    pane = %{
      id: "child-session:alpha",
      child_id: "alpha",
      stream_cursor: %{event_seq: 5},
      pane_state: %{}
    }

    assert ChildSessionReplay.surface_replay_cursor_gap(
             pane,
             existing_pane,
             "child-session:alpha"
           )
           |> get_in([:pane_state, :replay_gap_error]) == %{
             type: :recoverable_stream_gap,
             pane_id: "child-session:alpha",
             child_id: "alpha",
             expected_event_seq: 3,
             received_event_seq: 5,
             missing_event_seq_range: %{from: 3, to: 4},
             missing_event_seqs: [3, 4],
             acknowledged_stream_cursor: %{event_seq: 2, event_id: "evt-2"},
             recovery: :resume_from_acknowledged_stream_cursor
           }
  end
end
