defmodule Ourocode.Journal.RenderedSequenceRecordsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RenderedSequenceRecords

  test "builds rendered sequence journal records in render order" do
    rendered_pane = %{
      id: "pane-1",
      child_id: "child-1",
      updated_at_ms: 1_099,
      pane_state: %{
        stream_entries: [
          %{event_seq: 11, runtime_seq: 1, child_event_id: "event-11", token: "alpha"},
          %{event_seq: 12, runtime_seq: 2, token: "beta", occurred_at_ms: 1_012}
        ]
      },
      rendered_sequences: [
        %{id: "sequence-11", event_seq: 11, runtime_seq: 1, rendered_index: 1},
        %{id: "sequence-12", event_seq: 12, runtime_seq: 2, rendered_index: 2}
      ]
    }

    assert RenderedSequenceRecords.records(rendered_pane) == [
             %{
               type: :rendered_sequence_entry,
               source: :pane_model,
               pane_id: "pane-1",
               child_id: "child-1",
               child_event_id: "event-11",
               rendered_sequence_id: "sequence-11",
               rendered_event_seq: 11,
               runtime_seq: 1,
               rendered_index: 1,
               rendered_sequence: %{
                 id: "sequence-11",
                 event_seq: 11,
                 runtime_seq: 1,
                 rendered_index: 1
               },
               payload: %{
                 event_seq: 11,
                 runtime_seq: 1,
                 child_event_id: "event-11",
                 token: "alpha"
               },
               occurred_at_ms: 1_099
             },
             %{
               type: :rendered_sequence_entry,
               source: :pane_model,
               pane_id: "pane-1",
               child_id: "child-1",
               child_event_id: nil,
               rendered_sequence_id: "sequence-12",
               rendered_event_seq: 12,
               runtime_seq: 2,
               rendered_index: 2,
               rendered_sequence: %{
                 id: "sequence-12",
                 event_seq: 12,
                 runtime_seq: 2,
                 rendered_index: 2
               },
               payload: %{event_seq: 12, runtime_seq: 2, token: "beta", occurred_at_ms: 1_012},
               occurred_at_ms: 1_012
             }
           ]
  end

  test "supports string keyed panes and sequence-specific identity values" do
    rendered_pane = %{
      "id" => "pane-fallback",
      "child_id" => "child-fallback",
      "updated_at_ms" => 2_099,
      "pane_state" => %{
        "stream_entries" => [
          %{"event_seq" => 21, "runtime_seq" => 4, "child_event_id" => "payload-event"}
        ]
      },
      "rendered_sequences" => [
        %{
          "id" => "sequence-specific",
          "pane_id" => "pane-specific",
          "child_id" => "child-specific",
          "child_event_id" => "sequence-event",
          "event_seq" => 21,
          "runtime_seq" => 4,
          "rendered_index" => 7
        }
      ]
    }

    assert [
             %{
               pane_id: "pane-specific",
               child_id: "child-specific",
               child_event_id: "sequence-event",
               rendered_sequence_id: "sequence-specific",
               rendered_event_seq: 21,
               runtime_seq: 4,
               rendered_index: 7,
               occurred_at_ms: 2_099
             }
           ] = RenderedSequenceRecords.records(rendered_pane)
  end
end
