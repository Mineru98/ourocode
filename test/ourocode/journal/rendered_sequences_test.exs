defmodule Ourocode.Journal.RenderedSequencesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RenderedSequences

  test "extracts summaries from nested rendered pane collections" do
    rendered_output = %{
      working: [
        %{
          id: "pane-1",
          child_id: "child-1",
          rendered_sequences: [
            %{id: "seq-1", event_seq: 1, runtime_seq: 11, rendered_index: 0},
            %{
              rendered_sequence_id: "seq-2",
              child_id: "child-2",
              rendered_event_seq: 2,
              pane_id: "pane-2"
            }
          ]
        }
      ],
      completed: [
        %{
          "id" => "pane-3",
          "child_id" => "child-3",
          "rendered_sequences" => [%{"id" => "seq-3", "event_seq" => 3}]
        }
      ]
    }

    assert RenderedSequences.summaries(rendered_output) == [
             %{
               rendered_sequence_id: "seq-1",
               child_id: "child-1",
               pane_id: "pane-1",
               rendered_event_seq: 1,
               runtime_seq: 11,
               rendered_index: 0
             },
             %{
               rendered_sequence_id: "seq-2",
               child_id: "child-2",
               pane_id: "pane-2",
               rendered_event_seq: 2,
               runtime_seq: nil,
               rendered_index: nil
             },
             %{
               rendered_sequence_id: "seq-3",
               child_id: "child-3",
               pane_id: "pane-3",
               rendered_event_seq: 3,
               runtime_seq: nil,
               rendered_index: nil
             }
           ]
  end

  test "extracts summaries and event keys from standalone rendered sequence entries" do
    entries = [
      %{
        type: :rendered_sequence_entry,
        child_id: "child-1",
        rendered_sequence_id: "seq-1",
        rendered_event_seq: 7,
        runtime_seq: 17
      },
      %{"type" => "rendered_sequence_entry", "child_id" => "child-2", "id" => "seq-2"}
    ]

    assert RenderedSequences.summaries(entries) == [
             %{
               rendered_sequence_id: "seq-1",
               child_id: "child-1",
               pane_id: nil,
               rendered_event_seq: 7,
               runtime_seq: 17,
               rendered_index: nil
             },
             %{
               rendered_sequence_id: "seq-2",
               child_id: "child-2",
               pane_id: nil,
               rendered_event_seq: nil,
               runtime_seq: nil,
               rendered_index: nil
             }
           ]

    assert RenderedSequences.event_keys(entries) ==
             MapSet.new([{"child-1", 7}, {"child-2", nil}])
  end

  test "returns empty collections for non-rendered output" do
    assert RenderedSequences.summaries(%{lines: ["no sequences"]}) == []
    assert RenderedSequences.event_keys(nil) == MapSet.new()
    assert RenderedSequences.sources(:ignored) == []
  end
end
