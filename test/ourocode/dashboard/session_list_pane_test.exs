defmodule Ourocode.Dashboard.SessionListPaneTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.SessionListPane

  test "renders compact rows for active and running sessions only" do
    sessions = [
      %{
        status: :active,
        task_input: "Investigate child stream visibility",
        parent_call_id: "parent-1",
        runtime_source: "ouroboros",
        transport: :stdio,
        external_ids: %{
          session_id: "session-1",
          child_id: "child-1"
        },
        stream_cursor: %{offset: 12},
        event_seq: 12,
        updated_at_ms: 1_715_000
      },
      %{
        "status" => "running",
        "task_input" => "Open Codex pane",
        "parent_call_id" => "parent-2",
        "runtime_source" => "codex",
        "transport" => "streamable_http",
        "external_ids" => %{
          "native_session_id" => "session-2",
          "childID" => "child-2"
        },
        "event_seq" => "3"
      },
      %{
        status: :completed,
        task_input: "Finished work",
        parent_call_id: "parent-3",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{session_id: "session-3", child_id: "child-3"},
        event_seq: 20
      }
    ]

    assert %{
             id: :working_sessions,
             title: "Working",
             empty?: false,
             rows: [active, running]
           } = SessionListPane.render(sessions)

    assert active == %{
             session_id: "session-1",
             child_id: "child-1",
             runtime_source: "ouroboros",
             transport: "stdio",
             status: "active",
             task_label: "Investigate child stream visibility",
             parent_call_id: "parent-1",
             event_seq: 12,
             stream_cursor: %{offset: 12},
             updated_at_ms: 1_715_000
           }

    assert running.session_id == "session-2"
    assert running.child_id == "child-2"
    assert running.runtime_source == "codex"
    assert running.transport == "streamable_http"
    assert running.status == "running"
    assert running.task_label == "Open Codex pane"
    assert running.parent_call_id == "parent-2"
    assert running.event_seq == 3
  end

  test "renders an empty working pane when there are no active sessions" do
    assert SessionListPane.render([%{status: :completed}]) == %{
             id: :working_sessions,
             title: "Working",
             empty?: true,
             rows: []
           }
  end

  test "renders compact rows for finished sessions only" do
    sessions = [
      %{
        status: :completed,
        task_input: "Summarize completed Ouroboros run",
        parent_call_id: "parent-3",
        runtime_source: "ouroboros-plugin",
        transport: :sse,
        external_ids: %{
          session_id: "session-3",
          child_id: "child-3",
          execution_id: "execution-3"
        },
        stream_cursor: %{last_event_id: "event-20"},
        event_seq: 20,
        updated_at_ms: 1_716_000
      },
      %{
        "status" => "failed",
        "task_input" => "Open failed Codex task",
        "parent_call_id" => "parent-4",
        "runtime_source" => "codex",
        "transport" => "streamable_http",
        "external_ids" => %{
          "native_session_id" => "session-4",
          "childID" => "child-4"
        },
        "event_seq" => "9"
      },
      %{
        status: :running,
        task_input: "Still streaming",
        parent_call_id: "parent-5",
        runtime_source: "opencode",
        transport: :stdio,
        external_ids: %{session_id: "session-5", child_id: "child-5"},
        event_seq: 1
      }
    ]

    assert %{
             id: :completed_sessions,
             title: "Completed",
             empty?: false,
             rows: [completed, failed]
           } = SessionListPane.render_completed(sessions)

    assert completed == %{
             session_id: "session-3",
             child_id: "child-3",
             runtime_source: "ouroboros-plugin",
             transport: "sse",
             status: "completed",
             task_label: "Summarize completed Ouroboros run",
             parent_call_id: "parent-3",
             event_seq: 20,
             stream_cursor: %{last_event_id: "event-20"},
             updated_at_ms: 1_716_000
           }

    assert failed.session_id == "session-4"
    assert failed.child_id == "child-4"
    assert failed.runtime_source == "codex"
    assert failed.transport == "streamable_http"
    assert failed.status == "failed"
    assert failed.task_label == "Open failed Codex task"
    assert failed.parent_call_id == "parent-4"
    assert failed.event_seq == 9
  end

  test "renders an empty completed pane when there are no finished sessions" do
    assert SessionListPane.render_completed([%{status: :running}]) == %{
             id: :completed_sessions,
             title: "Completed",
             empty?: true,
             rows: []
           }
  end

  test "formats compact terminal row with required metadata" do
    row =
      SessionListPane.compact_row(%{
        status: :running,
        task_input: "Describe a task for a new session",
        parent_call_id: "parent-99",
        runtime_source: "opencode",
        transport: :sse,
        external_ids: %{session_id: "session-99", child_id: "child-99"},
        event_seq: 7
      })

    assert SessionListPane.render_row(row) ==
             "[running] Describe a task for a new session session=session-99 child=child-99 runtime=opencode transport=sse parent=parent-99 seq=7"
  end
end
