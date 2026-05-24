defmodule Ourocode.Dashboard.ChildSessionRelationshipRecoveryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionRelationshipRecovery

  test "same_relationship? matches parent/child identity or strongest external session identity" do
    relationship = relationship(child_id: "child-alpha")

    assert ChildSessionRelationshipRecovery.same_relationship?(
             %{child_id: "child-alpha", parent_call_id: "parent-1"},
             relationship
           )

    assert ChildSessionRelationshipRecovery.same_relationship?(
             %{
               child_id: "different-child",
               parent_call_id: "parent-1",
               external_ids: %{"native_session_id" => "native-alpha"}
             },
             %{relationship | external_ids: %{"native_session_id" => "native-alpha"}}
           )

    refute ChildSessionRelationshipRecovery.same_relationship?(
             %{child_id: "different-child", parent_call_id: "other-parent", external_ids: %{}},
             relationship
           )
  end

  test "prepare_event seeds registry from an existing relationship pane and drops fully replayed entries" do
    state = %{
      working: [
        %{
          id: "child-session:child-alpha",
          child_id: "child-alpha",
          parent_call_id: "parent-1",
          external_ids: %{"session_id" => "session-alpha"},
          pane_state: %{
            stream_entries: [
              %{event_seq: 2, runtime_seq: 2, token: "already-live"}
            ]
          }
        }
      ],
      completed: [],
      focused: nil,
      open: []
    }

    assert {:ok, prepared_state, event} =
             ChildSessionRelationshipRecovery.prepare_event(
               state,
               relationship(
                 pane_id: "journal-pane-alpha",
                 pane_state: %{
                   stream_entries: [
                     %{event_seq: 2, runtime_seq: 2, token: "already-live"}
                   ]
                 },
                 latest_event_seq: 2
               )
             )

    assert prepared_state.child_pane_registry == %{
             "child-alpha" => "child-session:child-alpha"
           }

    refute Map.has_key?(event.pane_state, :stream_entries)
    assert event.pane_id == "journal-pane-alpha"
    assert event.child_id == "child-alpha"
  end

  test "prepare_event rejects non-map relationships" do
    assert ChildSessionRelationshipRecovery.prepare_event(%{}, nil) ==
             {:error, :invalid_relationship_recovery_index}
  end

  defp relationship(overrides) do
    %{
      parent_call_id: "parent-1",
      child_id: "child-alpha",
      pane_id: "journal-pane-alpha",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"session_id" => "session-alpha"},
      stream_cursor: %{event_seq: 1},
      acknowledged_stream_cursor: nil,
      pane_state: %{},
      status: :working,
      first_event_seq: 1,
      latest_event_seq: 1,
      event_seqs: [1],
      source_event_types: [:parent_call_event],
      occurred_at_ms: 10,
      created_at_ms: 10,
      updated_at_ms: 10
    }
    |> Map.merge(Map.new(overrides))
  end
end
