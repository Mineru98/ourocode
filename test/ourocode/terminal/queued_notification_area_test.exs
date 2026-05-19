defmodule Ourocode.Terminal.QueuedNotificationAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.Layout
  alias Ourocode.Dashboard.{SessionListPane, TaskPromptInput}

  alias Ourocode.Terminal.{
    FooterStateArea,
    HeaderStatusArea,
    ParentChildPaneArea,
    QueuedNotificationArea
  }

  test "renders pending queued notifications in a terminal-safe area" do
    queue_state = %{
      status: :ready,
      overflow_policy: :journal_and_summarize,
      replayable?: true,
      items: [
        %{
          id: "notif-1",
          status: :pending,
          source: :hook_lifecycle,
          target: "child-pane-1",
          priority: :high,
          event_seq: 42,
          queued_at_ms: 1_000,
          summary: "Hook started\nwaiting for response"
        },
        %{
          id: "notif-2",
          status: :delivered,
          source: :runtime,
          summary: "already delivered"
        }
      ]
    }

    area = QueuedNotificationArea.render(queue_state)
    frame = QueuedNotificationArea.render_text(area)

    assert area.kind == :queued_notification_area
    assert area.pending_count == 1
    assert area.overflow_policy == :journal_and_summarize
    assert area.replayable? == true
    assert area.layout.mode == :terminal_stack
    assert area.layout.region == :queued_notifications
    assert area.layout.bounded? == true

    assert frame =~ "+-- Queued Notifications (1) region=queued_notifications x=0 y=26 w=80 h=6"
    assert frame =~ "| policy=journal_and_summarize replayable?=true"
    assert frame =~ "| pending id=notif-1 source=hook_lifecycle target=child-pane-1"
    assert frame =~ "priority=high seq=42 queued_at_ms=1000"
    assert frame =~ ~s(summary="Hook started waiting for response")
    refute frame =~ "already delivered"
  end

  test "renders an empty pending notification area" do
    frame =
      QueuedNotificationArea.render_text(%{
        overflow_policy: :journal_and_summarize,
        replayable?: true,
        items: []
      })

    assert frame =~ "+-- Queued Notifications (0)"
    assert frame =~ "| empty"
  end

  test "reserves bounded layout space below sibling terminal regions without overlap" do
    sibling_area =
      ParentChildPaneArea.render(%{
        id: :mcp_runtime_hierarchy,
        roots: [],
        orphan_children: []
      })

    queue_state = %{
      overflow_policy: :journal_and_summarize,
      replayable?: true,
      items:
        Enum.map(1..8, fn index ->
          %{
            id: "notif-#{index}",
            status: :pending,
            source: :runtime,
            summary: "queued notification #{index}"
          }
        end)
    }

    area = QueuedNotificationArea.render(queue_state)
    frame = QueuedNotificationArea.render_text(area)
    rendered_lines = String.split(frame, "\n")

    refute Layout.overlaps?(sibling_area.parent_region, area.layout.rect)
    refute Layout.overlaps?(sibling_area.child_region, area.layout.rect)
    assert area.layout.rect == %{x: 0, y: 26, width: 80, height: 6}
    assert area.visible_count == 3
    assert area.overflow_count == 6
    assert length(rendered_lines) <= area.layout.rect.height
    assert frame =~ "overflow=6"
    assert frame =~ "additional queued notification(s) hidden by bounded layout"
    refute frame =~ "notif-8"
  end

  test "renders queued notifications in a reserved shell region without overlapping panes header or footer" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    header =
      HeaderStatusArea.render(%{
        status: :healthy,
        healthy?: true,
        context: %{project_dir: "/project/ourocode", cwd: "/project/ourocode"}
      })

    footer =
      FooterStateArea.render(%{
        panes: panes,
        runtime: %{
          queued_notifications: %{items: [%{id: "queued-shell-1", status: :pending}]}
        }
      })

    queue =
      QueuedNotificationArea.render(%{
        overflow_policy: :journal_and_summarize,
        replayable?: true,
        items: [
          %{
            id: "queued-shell-1",
            status: :pending,
            source: :runtime,
            summary: "background hook completed"
          }
        ]
      })

    pane_rects = [
      panes.working.layout.rect,
      panes.completed.layout.rect,
      panes.task_prompt.layout.rect,
      header.layout.rect,
      footer.layout.rect
    ]

    assert QueuedNotificationArea.render_text(queue) =~
             "+-- Queued Notifications (1) region=queued_notifications x=0 y=26 w=80 h=6"

    assert Enum.all?(pane_rects, fn rect ->
             not Layout.overlaps?(rect, queue.layout.rect)
           end)

    assert footer.layout.rect == %{x: 0, y: 33, width: 80, height: 6}
    assert queue.layout.rect.y + queue.layout.rect.height <= footer.layout.rect.y
  end
end
