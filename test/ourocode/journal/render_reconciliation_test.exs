defmodule Ourocode.Journal.RenderReconciliationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.RenderReconciliation

  test "reconcile_completed_child_streams reports missing rendered completed stream events" do
    journal_entries = [
      %{
        event_seq: 11,
        type: :parent_call_event,
        child_id: "child-reconcile-1",
        parent_call_id: "parent-reconcile-1",
        transport: :stdio,
        payload: %{"token" => "alpha"},
        occurred_at_ms: 1_011
      },
      %{
        event_seq: 12,
        type: :child_pane_completed,
        child_id: "child-reconcile-1",
        status: :completed
      }
    ]

    assert {:error,
            %{
              reason: :journaled_child_stream_events_missing_from_render,
              missing_count: 1,
              missing_rendered_events: [%{child_id: "child-reconcile-1", event_seq: 11}]
            }} = RenderReconciliation.reconcile_completed_child_streams(journal_entries, %{})
  end

  test "verify_rendered_sequences_journaled compares rendered sequence ids" do
    sequence_id = "rendered-seq:child-1:event=1"

    journal_entries = [
      %{type: :rendered_sequence_entry, child_id: "child-1", rendered_sequence_id: sequence_id}
    ]

    rendered_output = %{
      working: [
        %{
          child_id: "child-1",
          rendered_sequences: [
            %{id: sequence_id, event_seq: 1},
            %{id: "rendered-seq:child-1:event=2", event_seq: 2}
          ]
        }
      ]
    }

    assert {:error,
            %{
              reason: :rendered_sequences_missing_from_journal,
              missing_count: 1,
              rendered_sequence_count: 2
            }} =
             RenderReconciliation.verify_rendered_sequences_journaled(
               journal_entries,
               rendered_output
             )
  end
end
