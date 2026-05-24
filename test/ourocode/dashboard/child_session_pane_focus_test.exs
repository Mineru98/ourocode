defmodule Ourocode.Dashboard.ChildSessionPaneFocusTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneFocus
  alias Ourocode.Dashboard.ChildSessionPaneRegistration
  alias Ourocode.Dashboard.ChildSessionPanes

  test "focus selects existing pane by child id and appends it to open panes" do
    assert {:ok, state} =
             ChildSessionPaneRegistration.register(ChildSessionPanes.new(), %{
               child_id: "child-1",
               parent_call_id: "parent-1",
               runtime_source: "ouroboros",
               transport: :sse
             })

    state = %{state | focused: nil, open: []}

    assert {:ok, focused} = ChildSessionPaneFocus.focus(state, "child-1")

    assert [pane] = focused.working
    assert focused.focused == pane.id
    assert focused.open == [pane.id]
    assert pane.pane_state.focused? == true
  end

  test "focus selects existing pane by pane id" do
    assert {:ok, state} =
             ChildSessionPaneRegistration.register(ChildSessionPanes.new(), %{
               child_id: "child-1",
               parent_call_id: "parent-1",
               runtime_source: "ouroboros",
               transport: :streamable_http
             })

    pane_id = hd(state.working).id

    assert {:ok, focused} = ChildSessionPaneFocus.focus(%{state | focused: nil}, pane_id)
    assert focused.focused == pane_id
  end

  test "focus selects completed panes and runtime metadata aliases" do
    completed_pane = %{
      id: "child-session:completed-child",
      kind: :child_session,
      status: :completed,
      child_id: "completed-child",
      parent_call_id: "parent-completed",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"job_id" => "job-1"},
      stream_cursor: %{event_seq: 9},
      pane_state: %{focused?: false},
      created_at_ms: 1,
      updated_at_ms: 2
    }

    state =
      ChildSessionPanes.new()
      |> Map.merge(%{
        working: [],
        completed: [completed_pane],
        focused: nil,
        open: [],
        child_pane_registry: %{"completed-child" => completed_pane.id}
      })

    assert {:ok, focused} = ChildSessionPaneFocus.focus(state, completed_pane.id)
    assert focused.focused == completed_pane.id
    assert [%{pane_state: %{focused?: true}}] = focused.completed

    assert {:ok, state} =
             ChildSessionPaneRegistration.register(ChildSessionPanes.new(), %{
               child_id: "metadata-child",
               parent_call_id: "parent-metadata",
               runtime_source: "opencode",
               transport: :sse,
               external_ids: %{"session_id" => "runtime-session-1"}
             })

    assert {:ok, focused} =
             ChildSessionPaneFocus.focus(%{state | focused: nil}, "runtime-session-1")

    assert focused.focused == "child-session:metadata-child"
  end

  test "focus rejects invalid or missing panes" do
    assert ChildSessionPaneFocus.focus(ChildSessionPanes.new(), "") ==
             {:error, :invalid_child_session_focus}

    assert ChildSessionPaneFocus.focus(ChildSessionPanes.new(), "missing") ==
             {:error, :child_session_pane_not_found}

    assert ChildSessionPaneFocus.focus(%{}, "child") == {:error, :invalid_child_session_focus}
  end
end
