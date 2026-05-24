defmodule Ourocode.Dashboard.ChildSessionPaneLifecycleTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneLifecycle
  alias Ourocode.Dashboard.ChildSessionPanes

  test "applies runtime panes through stable child registry mapping" do
    pane = runtime_pane("runtime-child-1", event_seq: 1)

    state = ChildSessionPaneLifecycle.apply_runtime(ChildSessionPanes.new(), pane, nil)

    assert state.focused == "child-session:runtime-child-1"
    assert state.open == ["child-session:runtime-child-1"]
    assert state.child_pane_registry == %{"runtime-child-1" => "child-session:runtime-child-1"}
    assert [%{id: "child-session:runtime-child-1", child_id: "runtime-child-1"}] = state.working
    assert state.completed == []
  end

  test "runtime panes update existing children and keep sibling registry keys distinct" do
    state =
      ChildSessionPanes.new()
      |> ChildSessionPaneLifecycle.apply_runtime(runtime_pane("child-1", event_seq: 1), nil)
      |> ChildSessionPaneLifecycle.apply_runtime(runtime_pane("child-2", event_seq: 2), nil)
      |> ChildSessionPaneLifecycle.apply_runtime(
        runtime_pane("child-1",
          event_seq: 3,
          external_ids: %{"thread_id" => "thread-1"},
          updated_at_ms: 300
        ),
        nil
      )

    assert state.child_pane_registry == %{
             "child-1" => "child-session:child-1",
             "child-2" => "child-session:child-2"
           }

    assert state.open == ["child-session:child-1", "child-session:child-2"]

    assert [
             %{
               id: "child-session:child-1",
               external_ids: %{"childID" => "child-1", "thread_id" => "thread-1"},
               stream_cursor: %{event_seq: 3},
               updated_at_ms: 300
             },
             %{id: "child-session:child-2", stream_cursor: %{event_seq: 2}}
           ] = state.working
  end

  test "runtime fallback panes reuse existing compatible runtime identity" do
    state =
      ChildSessionPanes.new()
      |> ChildSessionPaneLifecycle.apply_runtime(
        fallback_runtime_pane(:session_id, "session-1", event_seq: 1),
        nil
      )
      |> ChildSessionPaneLifecycle.apply_runtime(
        fallback_runtime_pane(:thread_id, "thread-1",
          event_seq: 2,
          external_ids: %{"session_id" => "session-1"}
        ),
        nil
      )

    assert state.open == ["child-session:fallback:session_id:session-1"]

    assert [
             %{
               id: "child-session:fallback:session_id:session-1",
               child_id: "fallback:session_id:session-1",
               external_ids: %{
                 "session_id" => "session-1",
                 "thread_id" => "thread-1",
                 "fallback_child_id" => "fallback:session_id:session-1",
                 "fallback_child_id_source" => "session_id"
               },
               stream_cursor: %{event_seq: 2, child_id: "fallback:session_id:session-1"}
             }
           ] = state.working
  end

  test "applies persisted completed panes to completed collection and focus state" do
    pane = %{
      id: "persisted-pane-1",
      kind: :child_session,
      status: :completed,
      child_id: "persisted-child-1",
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :stdio,
      external_ids: %{"childID" => "persisted-child-1"},
      stream_cursor: %{event_seq: 3, transport: :stdio, child_id: "persisted-child-1"},
      pane_state: %{open?: true, focused?: true, stream_entries: []},
      created_at_ms: 100,
      updated_at_ms: 300
    }

    state =
      ChildSessionPaneLifecycle.apply_persisted(
        ChildSessionPanes.new(),
        pane,
        :child_pane_completed
      )

    assert state.focused == "persisted-pane-1"
    assert state.open == ["persisted-pane-1"]
    assert state.child_pane_registry == %{"persisted-child-1" => "persisted-pane-1"}
    assert state.working == []

    assert [%{id: "persisted-pane-1", status: :completed, pane_state: %{focused?: true}}] =
             state.completed
  end

  defp runtime_pane(child_id, overrides) do
    event_seq = Keyword.fetch!(overrides, :event_seq)
    external_ids = Keyword.get(overrides, :external_ids, %{})

    %{
      id: "child-session:" <> child_id,
      kind: :child_session,
      status: :working,
      child_id: child_id,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :sse,
      external_ids: Map.put(external_ids, "childID", child_id),
      stream_cursor: %{event_seq: event_seq, transport: :sse, child_id: child_id},
      pane_state: %{open?: true, focused?: false, stream_entries: [], last_event_seq: event_seq},
      created_at_ms: Keyword.get(overrides, :created_at_ms, event_seq * 100),
      updated_at_ms: Keyword.get(overrides, :updated_at_ms, event_seq * 100)
    }
  end

  defp fallback_runtime_pane(source, value, overrides) do
    event_seq = Keyword.fetch!(overrides, :event_seq)
    child_id = "fallback:#{source}:#{value}"

    external_ids =
      overrides
      |> Keyword.get(:external_ids, %{})
      |> Map.put(Atom.to_string(source), value)
      |> Map.put("fallback_child_id", child_id)
      |> Map.put("fallback_child_id_source", Atom.to_string(source))
      |> Map.put("child_id", child_id)

    %{
      id: "child-session:" <> child_id,
      kind: :child_session,
      status: :working,
      child_id: child_id,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      transport: :sse,
      external_ids: external_ids,
      stream_cursor: %{event_seq: event_seq, transport: :sse, child_id: child_id},
      pane_state: %{open?: true, focused?: false, stream_entries: [], last_event_seq: event_seq},
      created_at_ms: event_seq * 100,
      updated_at_ms: event_seq * 100
    }
  end
end
