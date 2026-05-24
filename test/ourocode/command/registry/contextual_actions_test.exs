defmodule Ourocode.Command.Registry.ContextualActionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.ContextualActions
  alias Ourocode.Runtime.FocusState

  test "returns no entries when focus is not a concrete child session" do
    assert ContextualActions.entries(%{
             focus_state: FocusState.new(),
             pane_model: %{
               panes: %{parent: %{id: :parent, kind: :parent_session}},
               open: [:parent]
             }
           }) == []
  end

  test "returns interrupt and cancel entries for the focused child session" do
    child_pane_id = "child-session:alpha"

    pane_model = %{
      panes: %{
        child_pane_id => %{
          id: child_pane_id,
          kind: :child_session,
          child_id: "alpha",
          transport: :stdio
        }
      },
      open: [child_pane_id]
    }

    assert {:ok, focus_state, _event} =
             FocusState.focus_pane(FocusState.new(), child_pane_id, pane_model)

    entries = ContextualActions.entries(focus_state: focus_state, pane_model: pane_model)

    assert Enum.map(entries, & &1.slash) == ["/interrupt", "/cancel"]

    interrupt = Enum.find(entries, &(&1.slash == "/interrupt"))
    cancel = Enum.find(entries, &(&1.slash == "/cancel"))

    assert cancel.slash == "/cancel"
    assert cancel.run_spec.child_session_id == "alpha"
    assert cancel.run_spec.child_pane_id == child_pane_id
    assert cancel.metadata.contextual? == true

    assert interrupt.slash == "/interrupt"
    assert interrupt.run_spec.child_session_id == "alpha"
    assert interrupt.run_spec.child_pane_id == child_pane_id
    assert interrupt.metadata.focused_child_session.kind == :child_session
  end
end
