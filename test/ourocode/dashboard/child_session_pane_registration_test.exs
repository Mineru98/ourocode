defmodule Ourocode.Dashboard.ChildSessionPaneRegistrationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneRegistration
  alias Ourocode.Dashboard.ChildSessionPanes

  test "register creates a stable working pane from runtime metadata" do
    metadata = %{
      child_id: "child-1",
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"session_id" => "session-1"},
      stream_cursor: %{event_seq: 3},
      pane_state: %{summary: "running"},
      created_at_ms: 100,
      updated_at_ms: 120
    }

    assert {:ok, state} = ChildSessionPaneRegistration.register(ChildSessionPanes.new(), metadata)

    assert [pane] = state.working
    assert pane.child_id == "child-1"
    assert pane.parent_call_id == "parent-1"
    assert pane.external_ids["childID"] == "child-1"
    assert pane.external_ids["session_id"] == "session-1"
    assert pane.stream_cursor.child_id == "child-1"
    assert pane.stream_cursor.transport == :streamable_http
    assert pane.stream_cursor.event_seq == 3
    assert pane.pane_state.summary == "running"
    assert state.focused == pane.id
    assert state.open == [pane.id]
    assert state.child_pane_registry["child-1"] == pane.id
  end

  test "register updates the existing pane for repeated child metadata" do
    metadata = %{
      child_id: "child-1",
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      transport: :sse,
      updated_at_ms: 100
    }

    assert {:ok, state} = ChildSessionPaneRegistration.register(ChildSessionPanes.new(), metadata)
    assert [first] = state.working

    assert {:ok, state} =
             ChildSessionPaneRegistration.register(
               state,
               Map.merge(metadata, %{
                 updated_at_ms: 150,
                 stream_cursor: %{event_seq: 8},
                 pane_state: %{last_text: "done"}
               })
             )

    assert [updated] = state.working
    assert updated.id == first.id
    assert updated.updated_at_ms == 150
    assert updated.stream_cursor.event_seq == 8
    assert updated.pane_state.last_text == "done"
    assert state.open == [first.id]
  end

  test "register reuses a compatible fallback pane by runtime session identity" do
    assert {:ok, state} =
             ChildSessionPaneRegistration.register(ChildSessionPanes.new(), %{
               child_id: "fallback:session_id:metadata-session-1",
               parent_call_id: "parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{
                 "session_id" => "metadata-session-1",
                 "fallback_child_id" => "fallback:session_id:metadata-session-1"
               },
               created_at_ms: 100,
               updated_at_ms: 100
             })

    fallback_pane_id = "child-session:fallback:session_id:metadata-session-1"

    assert {:ok, state} =
             ChildSessionPaneRegistration.register(state, %{
               child_id: "real-child-1",
               parent_call_id: "parent-1",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "metadata-session-1"},
               stream_cursor: %{event_seq: 2},
               pane_state: %{title: "Real child session"},
               updated_at_ms: 200
             })

    assert state.child_pane_registry == %{
             "fallback:session_id:metadata-session-1" => fallback_pane_id,
             "real-child-1" => fallback_pane_id
           }

    assert [
             %{
               id: ^fallback_pane_id,
               child_id: "real-child-1",
               stream_cursor: %{event_seq: 2, child_id: "real-child-1"},
               pane_state: %{title: "Real child session"},
               created_at_ms: 100,
               updated_at_ms: 200
             }
           ] = state.working
  end

  test "register rejects invalid state or metadata" do
    assert ChildSessionPaneRegistration.register(ChildSessionPanes.new(), %{}) ==
             {:error, :invalid_child_pane_metadata}

    assert ChildSessionPaneRegistration.register(%{}, %{
             child_id: "child",
             parent_call_id: "parent",
             runtime_source: "ouroboros",
             transport: :sse
           }) == {:error, :invalid_child_pane_metadata}
  end
end
