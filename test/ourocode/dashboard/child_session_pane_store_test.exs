defmodule Ourocode.Dashboard.ChildSessionPaneStoreTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneStore

  test "distinct keeps first pane for each id and ignores malformed entries" do
    assert ChildSessionPaneStore.distinct([
             %{id: "pane-1", value: 1},
             %{id: "pane-2", value: 2},
             %{id: "pane-1", value: 3},
             %{value: 4}
           ]) == [
             %{id: "pane-1", value: 1},
             %{id: "pane-2", value: 2}
           ]
  end

  test "merge preserves existing renderer and ack cursor while deduping stream entries" do
    existing =
      pane(
        updated_at_ms: 10,
        stream_cursor: %{event_seq: 1},
        external_ids: %{"session_id" => "old"},
        pane_state: %{
          renderer: :custom,
          last_acknowledged_stream_cursor: %{event_seq: 1},
          stream_entries: [
            %{child_event_id: "evt-1", token: "first"},
            %{event_seq: 2, token: "same"}
          ]
        }
      )

    incoming =
      pane(
        updated_at_ms: 20,
        stream_cursor: %{runtime_seq: 3},
        external_ids: %{"thread_id" => "thread-1"},
        pane_state: %{
          renderer: :default_child_session,
          last_acknowledged_stream_cursor: nil,
          stream_entries: [
            %{child_event_id: "evt-1", token: "duplicate"},
            %{event_seq: 2, token: "same"},
            %{event_seq: 3, token: "new"}
          ]
        }
      )

    merged = ChildSessionPaneStore.merge(existing, incoming)

    assert merged.updated_at_ms == 20
    assert merged.stream_cursor == %{event_seq: 1, runtime_seq: 3}
    assert merged.external_ids == %{"session_id" => "old", "thread_id" => "thread-1"}
    assert merged.pane_state.renderer == :custom
    assert merged.pane_state.last_acknowledged_stream_cursor == %{event_seq: 1}

    assert merged.pane_state.stream_entries == [
             %{child_event_id: "evt-1", token: "first"},
             %{event_seq: 2, token: "same"},
             %{event_seq: 3, token: "new"}
           ]
  end

  test "apply_updates changes mutable metadata and preserves immutable identity" do
    pane =
      pane(
        status: :working,
        runtime_source: "old",
        transport: :stdio,
        updated_at_ms: 10,
        external_ids: %{"childID" => "child-1"},
        stream_cursor: %{event_seq: 1, transport: :stdio, child_id: "child-1"},
        pane_state: %{focused?: false}
      )

    updated =
      ChildSessionPaneStore.apply_updates(pane, %{
        status: "completed",
        runtime_source: "new",
        transport: "sse",
        external_ids: %{"session_id" => "session-1"},
        stream_cursor: %{event_seq: 2},
        pane_state: %{focused?: true},
        updated_at_ms: 30,
        id: "other",
        child_id: "other-child"
      })

    assert updated.id == "pane-1"
    assert updated.child_id == "child-1"
    assert updated.parent_call_id == "parent-1"
    assert updated.created_at_ms == 1
    assert updated.status == :completed
    assert updated.runtime_source == "new"
    assert updated.transport == :sse
    assert updated.updated_at_ms == 30
    assert updated.external_ids == %{"childID" => "child-1", "session_id" => "session-1"}
    assert updated.stream_cursor == %{event_seq: 2, transport: :sse, child_id: "child-1"}
    assert updated.pane_state == %{focused?: true}
  end

  test "list helpers replace, upsert, focus, and append without duplicates" do
    panes = [pane(id: "pane-1"), pane(id: "pane-2")]
    updated = pane(id: "pane-2", updated_at_ms: 99)

    assert ChildSessionPaneStore.replace(panes, "pane-2", updated) == [
             pane(id: "pane-1"),
             updated
           ]

    assert ChildSessionPaneStore.reject(panes, "pane-1") == [pane(id: "pane-2")]

    assert ChildSessionPaneStore.upsert(panes, updated, &Map.put(&1, :updated_at_ms, 99)) == [
             pane(id: "pane-1"),
             updated
           ]

    assert Enum.map(ChildSessionPaneStore.mark_focused(panes, "pane-2"), & &1.pane_state) == [
             %{focused?: false},
             %{focused?: true}
           ]

    assert ChildSessionPaneStore.append_once(["pane-1"], "pane-1") == ["pane-1"]
    assert ChildSessionPaneStore.append_once(["pane-1"], "pane-2") == ["pane-1", "pane-2"]
  end

  defp pane(overrides) do
    %{
      id: Keyword.get(overrides, :id, "pane-1"),
      kind: :child_session,
      status: Keyword.get(overrides, :status, :working),
      child_id: Keyword.get(overrides, :child_id, "child-1"),
      parent_call_id: Keyword.get(overrides, :parent_call_id, "parent-1"),
      runtime_source: Keyword.get(overrides, :runtime_source, "runtime"),
      transport: Keyword.get(overrides, :transport, :streamable_http),
      external_ids: Keyword.get(overrides, :external_ids, %{}),
      stream_cursor: Keyword.get(overrides, :stream_cursor, %{}),
      pane_state: Keyword.get(overrides, :pane_state, %{focused?: false}),
      created_at_ms: Keyword.get(overrides, :created_at_ms, 1),
      updated_at_ms: Keyword.get(overrides, :updated_at_ms, 2)
    }
  end
end
