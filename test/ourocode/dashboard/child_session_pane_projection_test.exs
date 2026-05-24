defmodule Ourocode.Dashboard.ChildSessionPaneProjectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneProjection

  test "renders distinct working panes and hides completed panes already represented as working" do
    pane = pane(%{})

    rendered =
      ChildSessionPaneProjection.render_collection(
        %{
          working: [pane, pane],
          completed: [%{pane | status: :completed}],
          focused: pane.id,
          open: [pane.id]
        },
        %{"alpha" => pane.id}
      )

    assert rendered.id == :child_session_panes
    assert rendered.empty? == false
    assert rendered.focused == pane.id
    assert rendered.child_pane_registry == %{"alpha" => pane.id}
    assert Enum.map(rendered.working, & &1.id) == [pane.id]
    assert rendered.completed == []
  end

  test "returns focused pane state without mutating collection projection" do
    pane = pane(%{})

    assert {:ok, focused} =
             ChildSessionPaneProjection.focused_state(%{
               working: [pane],
               completed: [],
               focused: pane.id
             })

    assert focused.id == pane.id
    assert focused.pane_state.focused? == true

    assert ChildSessionPaneProjection.focused_state(%{focused: nil}) ==
             {:error, :no_focused_child_session_pane}
  end

  test "returns completed focused pane state" do
    pane = pane(%{id: "child-session:completed", status: :completed})

    assert {:ok, focused} =
             ChildSessionPaneProjection.focused_state(%{
               working: [],
               completed: [pane],
               focused: pane.id
             })

    assert focused.id == pane.id
    assert focused.status == :completed
    assert focused.pane_state.focused? == true
  end

  test "rejects stale focused pane ids without mutating state" do
    state = %{
      working: [],
      completed: [],
      focused: "child-session:missing",
      open: ["child-session:missing"],
      child_pane_registry: %{"missing" => "child-session:missing"}
    }

    assert ChildSessionPaneProjection.focused_state(state) ==
             {:error, :focused_child_session_pane_not_found}

    assert state.open == ["child-session:missing"]
    assert state.child_pane_registry == %{"missing" => "child-session:missing"}
  end

  defp pane(overrides) do
    Map.merge(
      %{
        id: "child-session:alpha",
        kind: :child_session,
        status: :working,
        child_id: "alpha",
        parent_call_id: "parent",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{},
        stream_cursor: %{},
        pane_state: %{stream_entries: []},
        created_at_ms: 1,
        updated_at_ms: 2
      },
      overrides
    )
  end
end
