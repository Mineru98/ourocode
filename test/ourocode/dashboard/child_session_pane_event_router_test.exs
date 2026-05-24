defmodule Ourocode.Dashboard.ChildSessionPaneEventRouterTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneEventRouter
  alias Ourocode.Journal.RelationshipRecoveryIndex

  test "keeps state unchanged for events that do not describe child panes" do
    state = new_state()

    assert ChildSessionPaneEventRouter.apply_event(state, %{type: :transport_started}) == state

    assert ChildSessionPaneEventRouter.apply_event(state, %{
             event_seq: 1,
             type: :transport_connected,
             transport: :sse,
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             external_ids: %{"childID" => "child-1"},
             notification: %{"params" => %{"childID" => "child-1"}}
           }) == state
  end

  test "applies runtime child session lifecycle events" do
    state =
      ChildSessionPaneEventRouter.apply_event(new_state(), %{
        type: :parent_call_event,
        transport: :sse,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"childID" => "child-1"},
        payload: %{"childID" => "child-1", "seq" => 1, "token" => "hello"},
        event_seq: 10,
        occurred_at_ms: 100
      })

    assert [%{child_id: "child-1", parent_call_id: "parent-1"}] = state.working
    assert state.focused == "child-session:child-1"
    assert state.open == ["child-session:child-1"]
    assert state.child_pane_registry == %{"child-1" => "child-session:child-1"}
  end

  test "recovers from journal by replaying events in order" do
    events = [
      %{
        type: :parent_call_event,
        transport: :stdio,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{"childID" => "child-1"},
        payload: %{"childID" => "child-1", "seq" => 1},
        event_seq: 1,
        occurred_at_ms: 10
      }
    ]

    state = ChildSessionPaneEventRouter.recover_from_journal(events, new_state())

    assert [%{child_id: "child-1"}] = state.working
  end

  test "restores recovered relationships through prepared pane events" do
    index =
      RelationshipRecoveryIndex.new()
      |> Map.put(:relationships, [
        %{
          parent_call_id: "parent-1",
          child_id: "child-1",
          pane_id: "child-session:child-1",
          runtime_source: "synthetic",
          transport: :sse,
          external_ids: %{"childID" => "child-1"},
          stream_cursor: %{event_seq: 4},
          acknowledged_stream_cursor: %{event_seq: 3},
          pane_state: %{},
          status: :completed,
          first_event_seq: 1,
          latest_event_seq: 4,
          occurred_at_ms: 40,
          created_at_ms: 10,
          updated_at_ms: 40
        }
      ])

    assert {:ok, state} =
             ChildSessionPaneEventRouter.restore_recovered_relationships(new_state(), index)

    assert state.working == []
    assert [%{child_id: "child-1", status: :completed}] = state.completed
    assert state.child_pane_registry == %{"child-1" => "child-session:child-1"}
  end

  defp new_state do
    %{working: [], completed: [], focused: nil, open: [], child_pane_registry: %{}}
  end
end
