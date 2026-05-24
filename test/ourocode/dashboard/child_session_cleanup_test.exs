defmodule Ourocode.Dashboard.ChildSessionCleanupTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionCleanup

  test "parses child cleanup events with runtime child id aliases" do
    assert {:ok, %{kind: :child, child_id: "child-1"}} =
             ChildSessionCleanup.from_event(%{
               cleanup_reason: :idle_timeout,
               stream_kind: :child,
               childID: " child-1 "
             })
  end

  test "parses session cleanup events from external ids" do
    assert {:ok, %{kind: :session, session_id: "session-1"}} =
             ChildSessionCleanup.from_event(%{
               cleanup_reason: :operation_timeout,
               stream_kind: :session,
               external_ids: %{"session_id" => " session-1 "}
             })
  end

  test "ignores cleanup events outside timeout cleanup reasons" do
    assert :ignore =
             ChildSessionCleanup.from_event(%{
               cleanup_reason: :normal,
               stream_kind: :child,
               child_id: "child-1"
             })
  end

  test "applies child cleanup by removing panes, focus, open ids, and registry entries" do
    state = %{
      working: [
        pane("child-1", session_id: "session-1"),
        pane("child-2", session_id: "session-2")
      ],
      completed: [],
      focused: "child-session:child-1",
      open: ["child-session:child-1", "child-session:child-2"],
      child_pane_registry: %{
        "child-1" => "child-session:child-1",
        "child-2" => "child-session:child-2"
      }
    }

    cleaned = ChildSessionCleanup.apply(state, %{kind: :child, child_id: "child-1"})

    assert Enum.map(cleaned.working, & &1.child_id) == ["child-2"]
    assert cleaned.focused == nil
    assert cleaned.open == ["child-session:child-2"]
    assert cleaned.child_pane_registry == %{"child-2" => "child-session:child-2"}
  end

  test "applies session cleanup across working and completed panes" do
    state = %{
      working: [pane("child-1", session_id: "session-1")],
      completed: [
        pane("child-2", session_id: "session-1"),
        pane("child-3", session_id: "session-3")
      ],
      focused: "child-session:child-3",
      open: ["child-session:child-1", "child-session:child-2", "child-session:child-3"],
      child_pane_registry: %{
        "child-1" => "child-session:child-1",
        "child-2" => "child-session:child-2",
        "child-3" => "child-session:child-3"
      }
    }

    cleaned = ChildSessionCleanup.apply(state, %{kind: :session, session_id: "session-1"})

    assert cleaned.working == []
    assert Enum.map(cleaned.completed, & &1.child_id) == ["child-3"]
    assert cleaned.focused == "child-session:child-3"
    assert cleaned.open == ["child-session:child-3"]
    assert cleaned.child_pane_registry == %{"child-3" => "child-session:child-3"}
  end

  defp pane(child_id, opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: "child-session:" <> child_id,
      child_id: child_id,
      external_ids: %{"session_id" => session_id}
    }
  end
end
