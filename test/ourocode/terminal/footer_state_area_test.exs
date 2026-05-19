defmodule Ourocode.Terminal.FooterStateAreaTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{Layout, SessionListPane, TaskPromptInput}
  alias Ourocode.Terminal.FooterStateArea

  test "renders terminal footer state with focus, stream, queue, transport, and replay status" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    area =
      FooterStateArea.render(%{
        ui_surface: :terminal,
        panes: panes,
        runtime: %{
          status: :ready,
          stream: %{status: :flowing},
          journal: %{status: :open},
          queued_notifications: %{
            items: [
              %{id: "queued-1", status: :pending},
              %{id: "queued-2", status: :delivered}
            ]
          },
          transports: [
            %{type: :stdio, status: :connected},
            %{type: :sse, status: :connecting},
            %{type: :streamable_http, status: :connected}
          ],
          replayable?: true
        }
      })

    assert area.id == :footer_state
    assert area.kind == :terminal_footer_state_area
    assert area.focus == :task_prompt
    assert area.layout_mode == :compact
    assert area.runtime_status == :ready
    assert area.stream_status == :flowing
    assert area.journal_status == :open
    assert area.queued_count == 1

    assert area.layout == %{
             mode: :terminal_stack,
             region: :footer_state,
             order: 99,
             rect: %{x: 0, y: 33, width: 80, height: 6}
           }

    assert area.transport_statuses == [
             "stdio:connected",
             "sse:connecting",
             "streamable_http:connected"
           ]

    text = FooterStateArea.render_text(area)

    assert text =~ "+-- State"
    assert text =~ "| surface=terminal focus=task_prompt layout=compact"
    assert text =~ "| runtime=ready stream=flowing journal=open"

    assert text =~
             "| queued=1 replayable?=true transports=stdio:connected,sse:connecting,streamable_http:connected"

    assert area.hook_activity == %{
             state: :idle,
             summary: "idle",
             hook_id: nil,
             hook_event: nil,
             event_count: 0
           }

    assert text =~ "| hooks=idle events=0"
  end

  test "renders compact active hook progress and event count from runtime hook lifecycle" do
    area =
      FooterStateArea.render(%{
        ui_surface: :terminal,
        panes: %{},
        runtime: %{
          status: :running,
          hook_lifecycle: %{
            event_count: 3,
            latest_started: %{
              type: :hook_started,
              event_seq: 4,
              hook_id: "hook-started-1",
              payload: %{"hook" => "before_child_dispatch"}
            },
            latest_progress: %{
              type: :hook_progress,
              event_seq: 6,
              hook_id: "hook-started-1",
              payload: %{"hook" => "before_child_dispatch"}
            },
            latest_response: %{
              type: :hook_response,
              event_seq: 2,
              hook_id: "hook-older-1",
              payload: %{"hook" => "after_init"}
            }
          }
        }
      })

    assert area.hook_activity == %{
             state: :running,
             summary: "Running before_child_dispatch hook",
             hook_id: "hook-started-1",
             hook_event: "before_child_dispatch",
             event_count: 3
           }

    text = FooterStateArea.render_text(area)

    assert text =~
             ~s(| hooks=running activity="Running before_child_dispatch hook" hook_id=hook-started-1 events=3)
  end

  test "treats a completed hook newer than the latest start as idle" do
    area =
      FooterStateArea.render(%{
        panes: %{},
        runtime: %{
          hook_lifecycle: %{
            event_count: 5,
            latest_started: %{type: :hook_started, event_seq: 4, hook_id: "hook-1"},
            latest_completed: %{type: :hook_completed, event_seq: 7, hook_id: "hook-1"}
          }
        }
      })

    assert area.hook_activity.state == :idle
    assert area.hook_activity.event_count == 5
    assert FooterStateArea.render_text(area) =~ "| hooks=idle events=5"
  end

  test "renders safe defaults when runtime state has not attached yet" do
    text = FooterStateArea.render_text(%{panes: %{}})

    assert text =~ "+-- State"
    assert text =~ "surface=terminal focus=none layout=unknown"
    assert text =~ "runtime=unknown stream=unknown journal=unknown"
    assert text =~ "queued=0 replayable?=false transports=none"
  end
end
