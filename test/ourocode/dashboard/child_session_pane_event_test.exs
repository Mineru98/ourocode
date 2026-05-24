defmodule Ourocode.Dashboard.ChildSessionPaneEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneEvent

  test "builds child panes from runtime lifecycle events" do
    event = %{
      event_seq: 7,
      type: :parent_call_started,
      transport: :streamable_http,
      parent_call_id: "parent-1",
      runtime_source: "opencode",
      external_ids: %{"childID" => " child-1 ", "session_id" => " session-1 "},
      occurred_at_ms: 700
    }

    assert {:ok, pane} = ChildSessionPaneEvent.from_lifecycle_event(event)
    assert pane.id == "child-session:child-1"
    assert pane.child_id == "child-1"
    assert pane.parent_call_id == "parent-1"
    assert pane.external_ids["childID"] == "child-1"
    assert pane.external_ids["session_id"] == "session-1"
    assert pane.stream_cursor == %{transport: :streamable_http, event_seq: 7, child_id: "child-1"}
    assert pane.pane_state.last_event_seq == 7
  end

  test "builds fallback child panes from parent event metadata" do
    event = %{
      event_seq: 3,
      type: :parent_call_event,
      transport: :stdio,
      parent_call_id: "parent-1",
      runtime_source: "synthetic",
      external_ids: %{"session_id" => " session-1 "},
      occurred_at_ms: 300,
      notification: %{"params" => %{"seq" => 1}}
    }

    assert {:ok, pane} = ChildSessionPaneEvent.from_lifecycle_event(event)

    assert pane.id == "child-session:fallback:session_id:session-1"
    assert pane.child_id == "fallback:session_id:session-1"
    assert pane.external_ids["session_id"] == "session-1"
    assert pane.external_ids["fallback_child_id"] == "fallback:session_id:session-1"
    assert pane.external_ids["fallback_child_id_source"] == "session_id"
    assert pane.stream_cursor.child_id == "fallback:session_id:session-1"
  end

  test "includes media placeholders from streamed image payloads" do
    event = %{
      event_seq: 12,
      type: :parent_call_event,
      transport: :sse,
      parent_call_id: "parent-image-1",
      runtime_source: "opencode",
      external_ids: %{"childID" => "child-image-1"},
      notification: %{
        "params" => %{
          "childID" => "child-image-1",
          "seq" => 1,
          "token" => "render",
          "images" => [
            %{"type" => "image/png", "url" => "file:///tmp/one.png"},
            %{"mime_type" => "image/jpeg", "data" => "base64"}
          ]
        }
      }
    }

    assert {:ok, pane} = ChildSessionPaneEvent.from_lifecycle_event(event)

    assert [
             %{
               token: "render",
               media_placeholders: ["[Image #1]", "[Image #2]"]
             }
           ] = pane.pane_state.stream_entries
  end

  test "builds child panes from persisted pane lifecycle records" do
    event = %{
      type: :child_pane_completed,
      pane_id: "pane-1",
      child_id: "child-1",
      parent_call_id: "parent-1",
      runtime_source: "opencode",
      transport: :sse,
      external_ids: %{"session_id" => "session-1"},
      stream_cursor: %{event_seq: 12},
      pane_state: %{last_event_seq: 12},
      created_at_ms: 100,
      updated_at_ms: 200
    }

    assert {:ok, pane, :child_pane_completed} =
             ChildSessionPaneEvent.from_pane_lifecycle_event(event)

    assert pane.id == "pane-1"
    assert pane.status == :completed
    assert pane.external_ids["childID"] == "child-1"
    assert pane.stream_cursor == %{event_seq: 12, transport: :sse, child_id: "child-1"}
    assert pane.pane_state.last_event_seq == 12
  end

  test "stabilizes compatible fallback panes to an existing runtime identity" do
    existing = %{
      id: "child-session:fallback:session_id:session-1",
      child_id: "fallback:session_id:session-1",
      external_ids: %{
        "session_id" => "session-1",
        "fallback_child_id" => "fallback:session_id:session-1",
        "fallback_child_id_source" => "session_id"
      },
      stream_cursor: %{event_seq: 1, child_id: "fallback:session_id:session-1"}
    }

    incoming = %{
      id: "child-session:fallback:thread_id:thread-1",
      child_id: "fallback:thread_id:thread-1",
      external_ids: %{
        "session_id" => "session-1",
        "thread_id" => "thread-1",
        "fallback_child_id" => "fallback:thread_id:thread-1",
        "fallback_child_id_source" => "thread_id"
      },
      stream_cursor: %{event_seq: 2, child_id: "fallback:thread_id:thread-1"}
    }

    pane = ChildSessionPaneEvent.stabilize_fallback_child_id([existing], incoming)

    assert pane.id == existing.id
    assert pane.child_id == existing.child_id
    assert pane.external_ids["fallback_child_id"] == existing.child_id
    assert pane.external_ids["fallback_child_id_source"] == "session_id"
    assert pane.stream_cursor.child_id == existing.child_id
  end
end
