defmodule Ourocode.Dashboard.LayoutRecoveryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.LayoutRecovery

  test "applies layout lifecycle events with atom metadata" do
    state = %{
      working: %{title: "Working"},
      completed: %{title: "Completed"},
      focused: nil,
      open: []
    }

    event = %{
      type: :dashboard_layout_applied,
      layout: %{
        mode: :compact,
        regions: %{
          session_lists: %{
            x: 0,
            y: 0,
            width: 36,
            height: 21,
            panes: [:working_sessions, :completed_sessions]
          }
        }
      },
      pane_layouts: %{
        working: %{
          mode: :compact,
          region: :session_lists,
          order: 1,
          rect: %{x: 0, y: 0, width: 36, height: 10}
        },
        completed: %{
          mode: :compact,
          region: :session_lists,
          order: 2,
          rect: %{x: 0, y: 11, width: 36, height: 10}
        }
      },
      focused: :working_sessions,
      open: [:working_sessions, :completed_sessions]
    }

    recovered = LayoutRecovery.apply_event(state, event)

    assert recovered.layout.regions.session_lists.panes == [
             :working_sessions,
             :completed_sessions
           ]

    assert recovered.working.layout.rect == %{x: 0, y: 0, width: 36, height: 10}
    assert recovered.completed.layout.rect == %{x: 0, y: 11, width: 36, height: 10}
    assert recovered.focused == :working_sessions
    assert recovered.open == [:working_sessions, :completed_sessions]
  end

  test "normalizes string-keyed JSON layout events" do
    recovered =
      LayoutRecovery.apply_event(%{task_prompt: %{}}, %{
        "type" => "dashboard_layout_updated",
        "pane_layouts" => %{
          "task_prompt" => %{
            "mode" => "compact",
            "region" => "task_prompt",
            "order" => 1,
            "rect" => %{"x" => 0, "y" => 24, "width" => 80, "height" => 3}
          }
        },
        "focused" => "task_prompt",
        "open" => ["working_sessions", "completed_sessions", "task_prompt"]
      })

    assert recovered.task_prompt.layout == %{
             mode: :compact,
             region: :task_prompt,
             order: 1,
             rect: %{x: 0, y: 24, width: 80, height: 3}
           }

    assert recovered.focused == :task_prompt
    assert recovered.open == [:working_sessions, :completed_sessions, :task_prompt]
  end

  test "ignores non-layout events" do
    assert LayoutRecovery.apply_event(%{focused: :working}, %{type: :parent_call_started}) ==
             %{focused: :working}
  end

  test "recovers from multiple journal events in order" do
    recovered =
      LayoutRecovery.recover_from_journal(
        [
          %{
            type: :dashboard_layout_applied,
            pane_layouts: %{working: %{rect: %{x: 0, y: 0, width: 36, height: 10}}}
          },
          %{
            type: :dashboard_layout_updated,
            pane_layouts: %{working: %{rect: %{x: 1, y: 2, width: 30, height: 8}}}
          }
        ],
        %{working: %{}}
      )

    assert recovered.working.layout.rect == %{x: 1, y: 2, width: 30, height: 8}
  end
end
