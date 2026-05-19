defmodule Ourocode.Terminal.PromptFooterLayoutTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.{Layout, SessionListPane, TaskPromptInput}
  alias Ourocode.Terminal.PromptFooterLayout

  test "renders prompt, queue, and footer controls in a stable non-overlapping bottom region" do
    panes =
      %{
        working: SessionListPane.render([]),
        completed: SessionListPane.render_completed([]),
        task_prompt: TaskPromptInput.render(value: "/help"),
        focused: nil,
        open: []
      }
      |> Layout.apply_compact_session_list_layout()

    bottom =
      PromptFooterLayout.render(%{
        status: :healthy,
        context: %{project_dir: "/project/ourocode", cwd: "/project/ourocode"},
        panes: panes,
        runtime: %{
          queued_notifications: %{
            overflow_policy: :journal_and_summarize,
            replayable?: true,
            items: [
              %{
                id: "queued-bottom-1",
                status: :pending,
                source: :hook_lifecycle,
                summary: "hook waiting for response"
              }
            ]
          },
          replayable?: true
        }
      })

    frame = PromptFooterLayout.render_text(bottom)
    sibling_rects = [panes.working.layout.rect, panes.completed.layout.rect]
    bottom_rects = Map.values(bottom.layout.regions)

    assert bottom.kind == :terminal_prompt_footer_layout
    assert bottom.stable_bottom_region? == true
    assert bottom.overlaps? == false

    assert bottom.layout == %{
             mode: :terminal_stack,
             region: :bottom_controls,
             order: 90,
             rect: %{x: 0, y: 22, width: 80, height: 17},
             regions: %{
               task_prompt: %{x: 0, y: 22, width: 72, height: 3},
               queued_notifications: %{x: 0, y: 26, width: 80, height: 6},
               footer_state: %{x: 0, y: 33, width: 80, height: 6}
             }
           }

    assert Enum.all?(sibling_rects, fn sibling_rect ->
             Enum.all?(bottom_rects, fn bottom_rect ->
               not Layout.overlaps?(sibling_rect, bottom_rect)
             end)
           end)

    assert frame =~ "+-- Task region=task_prompt x=0 y=22 w=72 h=3"
    assert frame =~ "| > /help"
    assert frame =~ "+-- Queued Notifications (1) region=queued_notifications x=0 y=26 w=80 h=6"
    assert frame =~ "hook waiting for response"
    assert frame =~ "+-- State"
  end
end
