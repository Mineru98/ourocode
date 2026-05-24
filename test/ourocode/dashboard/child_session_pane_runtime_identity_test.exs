defmodule Ourocode.Dashboard.ChildSessionPaneRuntimeIdentityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.ChildSessionPaneRuntimeIdentity

  test "extracts runtime child ids and normalizes external ids" do
    event = %{
      external_ids: %{"childID" => " child-1 ", "session_id" => " session-1 "}
    }

    assert ChildSessionPaneRuntimeIdentity.extract(event) ==
             {:ok, {"child-1", :runtime_child_id}}

    assert ChildSessionPaneRuntimeIdentity.external_ids(event, "child-1", :runtime_child_id) ==
             %{"childID" => "child-1", "session_id" => "session-1"}
  end

  test "extracts pane-key child ids and preserves pane key metadata" do
    event = %{external_ids: %{"pane_key" => "child-session:child-1"}}

    assert ChildSessionPaneRuntimeIdentity.extract(event) == {:ok, {"child-1", :pane_key}}

    assert ChildSessionPaneRuntimeIdentity.external_ids(event, "child-1", :pane_key) ==
             %{
               "pane_key" => "child-session:child-1",
               "child_id" => "child-1"
             }
  end

  test "extracts fallback child ids from stdout jsonl runtime metadata" do
    event = %{
      type: :parent_call_event,
      parent_call_id: "parent-1",
      stdout_jsonl: [
        %{"session_id" => " session-1 ", "thread_id" => " thread-1 "}
      ],
      notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
    }

    assert ChildSessionPaneRuntimeIdentity.extract(event) ==
             {:ok, {"fallback:thread_id:thread-1", {:fallback, :thread_id}}}

    external_ids =
      ChildSessionPaneRuntimeIdentity.external_ids(
        event,
        "fallback:thread_id:thread-1",
        {:fallback, :thread_id}
      )

    assert external_ids[:session_id] == "session-1"
    assert external_ids[:thread_id] == "thread-1"
    assert external_ids["fallback_child_id"] == "fallback:thread_id:thread-1"
    assert external_ids["fallback_child_id_source"] == "thread_id"
    assert external_ids["child_id"] == "fallback:thread_id:thread-1"
  end

  test "extracts fallback child ids from SSE runtime event metadata" do
    event = %{
      type: :parent_call_event,
      parent_call_id: "parent-1",
      raw_event: %{
        "event" => "message",
        "id" => "sse-frame-1",
        "data" => %{
          "jsonrpc" => "2.0",
          "method" => "notifications/progress",
          "params" => %{
            "seq" => 1,
            "token" => "hello",
            "threadId" => "thread-sse-1",
            "metadata" => %{"sessionId" => "session-sse-1"}
          }
        }
      }
    }

    assert ChildSessionPaneRuntimeIdentity.extract(event) ==
             {:ok, {"fallback:thread_id:thread-sse-1", {:fallback, :thread_id}}}

    external_ids =
      ChildSessionPaneRuntimeIdentity.external_ids(
        event,
        "fallback:thread_id:thread-sse-1",
        {:fallback, :thread_id}
      )

    assert external_ids[:session_id] == "session-sse-1"
    assert external_ids[:thread_id] == "thread-sse-1"
    assert external_ids["fallback_child_id"] == "fallback:thread_id:thread-sse-1"
    assert external_ids["fallback_child_id_source"] == "thread_id"
  end

  test "primary runtime metadata wins over stdout fallback candidates" do
    event = %{
      type: :parent_call_event,
      parent_call_id: "parent-primary-1",
      external_ids: %{"session_id" => "primary-session-1"},
      stdout_jsonl: [
        %{"session_id" => "stdout-session-1", "thread_id" => "stdout-thread-1"}
      ],
      notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
    }

    assert ChildSessionPaneRuntimeIdentity.extract(event) ==
             {:ok, {"fallback:session_id:primary-session-1", {:fallback, :session_id}}}

    external_ids =
      ChildSessionPaneRuntimeIdentity.external_ids(
        event,
        "fallback:session_id:primary-session-1",
        {:fallback, :session_id}
      )

    assert external_ids["session_id"] == "primary-session-1"
    assert external_ids[:thread_id] == "stdout-thread-1"
    assert external_ids["fallback_child_id_source"] == "session_id"
  end

  test "stdout JSONL metadata wins over conflicting runtime event metadata" do
    event = %{
      type: :parent_call_event,
      parent_call_id: "parent-conflict-1",
      external_ids: %{},
      stdout_jsonl: [
        %{"session_id" => "stdout-session-1", "thread_id" => "stdout-thread-1"}
      ],
      raw_event: %{
        "event" => %{
          "data" => %{
            "threadId" => "runtime-thread-1",
            "sessionId" => "runtime-session-1"
          }
        }
      },
      notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
    }

    assert ChildSessionPaneRuntimeIdentity.extract(event) ==
             {:ok, {"fallback:thread_id:stdout-thread-1", {:fallback, :thread_id}}}

    external_ids =
      ChildSessionPaneRuntimeIdentity.external_ids(
        event,
        "fallback:thread_id:stdout-thread-1",
        {:fallback, :thread_id}
      )

    assert external_ids[:thread_id] == "stdout-thread-1"
    assert external_ids[:session_id] == "stdout-session-1"
    assert external_ids["fallback_child_id_source"] == "thread_id"
  end

  test "runtime event metadata is used when primary and stdout metadata are invalid" do
    event = %{
      type: :parent_call_event,
      parent_call_id: "parent-runtime-event-1",
      external_ids: %{:thread_id => " ", "session_id" => 123},
      stdout_jsonl: [
        %{"session_id" => 42, "thread_id" => " "}
      ],
      raw_event: %{
        "event" => %{
          "data" => %{
            "threadId" => "runtime-thread-1",
            "sessionId" => "runtime-session-1"
          }
        }
      },
      notification: %{"params" => %{"seq" => 1, "token" => "hello"}}
    }

    assert ChildSessionPaneRuntimeIdentity.extract(event) ==
             {:ok, {"fallback:thread_id:runtime-thread-1", {:fallback, :thread_id}}}

    external_ids =
      ChildSessionPaneRuntimeIdentity.external_ids(
        event,
        "fallback:thread_id:runtime-thread-1",
        {:fallback, :thread_id}
      )

    assert external_ids[:thread_id] == "runtime-thread-1"
    assert external_ids[:session_id] == "runtime-session-1"
    assert external_ids["fallback_child_id_source"] == "thread_id"
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

    pane = ChildSessionPaneRuntimeIdentity.stabilize_fallback_child_id([existing], incoming)

    assert pane.id == existing.id
    assert pane.child_id == existing.child_id
    assert pane.external_ids["fallback_child_id"] == existing.child_id
    assert pane.external_ids["fallback_child_id_source"] == "session_id"
    assert pane.stream_cursor.child_id == existing.child_id
  end

  test "does not merge conflicting fallback panes from the same source" do
    existing = %{
      id: "child-session:fallback:session_id:session-1",
      child_id: "fallback:session_id:session-1",
      external_ids: %{
        "session_id" => "session-1",
        "fallback_child_id" => "fallback:session_id:session-1",
        "fallback_child_id_source" => "session_id"
      },
      stream_cursor: %{child_id: "fallback:session_id:session-1"}
    }

    incoming = %{
      id: "child-session:fallback:session_id:session-2",
      child_id: "fallback:session_id:session-2",
      external_ids: %{
        "session_id" => "session-1",
        "fallback_child_id" => "fallback:session_id:session-2",
        "fallback_child_id_source" => "session_id"
      },
      stream_cursor: %{child_id: "fallback:session_id:session-2"}
    }

    assert ChildSessionPaneRuntimeIdentity.stabilize_fallback_child_id([existing], incoming) ==
             incoming
  end
end
