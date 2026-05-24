defmodule Ourocode.Dashboard.ChildSessionPaneAccessTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneAccess

  test "fetch returns only child session panes by stable pane id" do
    pane = child_pane("child-1")
    state = %{working: [pane], completed: [%{id: "other", kind: :parent_mcp}]}

    assert {:ok, ^pane} = ChildSessionPaneAccess.fetch(state, "child-session:child-1")
    assert {:error, :child_session_pane_not_found} = ChildSessionPaneAccess.fetch(state, "other")
  end

  test "update preserves immutable pane identity fields" do
    pane = child_pane("child-1")
    state = %{working: [pane], completed: []}

    assert {:ok, updated_state} =
             ChildSessionPaneAccess.update(state, pane.id, %{
               child_id: "rewritten-child",
               parent_call_id: "rewritten-parent",
               runtime_source: "opencode",
               transport: :sse,
               pane_state: %{title: "Updated"},
               updated_at_ms: 200
             })

    assert [
             %{
               id: "child-session:child-1",
               kind: :child_session,
               child_id: "child-1",
               parent_call_id: "parent-1",
               runtime_source: "opencode",
               transport: :sse,
               pane_state: %{title: "Updated"},
               updated_at_ms: 200
             }
           ] = updated_state.working
  end

  test "update rejects invalid state or missing panes" do
    assert {:error, :child_session_pane_not_found} =
             ChildSessionPaneAccess.update(%{working: [], completed: []}, "missing", %{})

    assert {:error, :invalid_child_pane_update} =
             ChildSessionPaneAccess.update(%{}, "missing", %{})
  end

  defp child_pane(child_id) do
    %{
      id: "child-session:" <> child_id,
      kind: :child_session,
      status: :working,
      child_id: child_id,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :stdio,
      external_ids: %{},
      stream_cursor: %{},
      pane_state: %{title: "Original"},
      created_at_ms: 100,
      updated_at_ms: 100
    }
  end
end
