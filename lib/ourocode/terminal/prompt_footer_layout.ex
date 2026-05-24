defmodule Ourocode.Terminal.PromptFooterLayout do
  @moduledoc """
  Stable bottom-region projection for terminal prompt and footer controls.

  Prompt input, queued notifications, and footer state are rendered as one
  terminal-owned bottom stack so the shell can prove those controls do not
  overlap each other or the session panes above them.
  """

  alias Ourocode.Dashboard.Layout

  alias Ourocode.Terminal.{
    FooterStateArea,
    PromptInputArea,
    QueuedNotificationArea,
    QueuedNotificationState
  }

  @type rendered_layout :: %{
          required(:kind) => :terminal_prompt_footer_layout,
          required(:layout) => map(),
          required(:prompt) => PromptInputArea.rendered_area(),
          required(:queued_notifications) => QueuedNotificationArea.rendered_area(),
          required(:footer) => FooterStateArea.rendered_area(),
          required(:stable_bottom_region?) => boolean(),
          required(:overlaps?) => boolean()
        }

  @doc """
  Builds the render-ready bottom control stack for a terminal shell frame.
  """
  @spec render(map()) :: rendered_layout()
  def render(%{panes: panes} = startup_result) when is_map(panes) do
    prompt = PromptInputArea.render(Map.fetch!(panes, :task_prompt))

    queue =
      startup_result
      |> QueuedNotificationState.from_startup_result()
      |> QueuedNotificationArea.render()

    footer = FooterStateArea.render(startup_result)

    rects = [prompt.layout.rect, queue.layout.rect, footer.layout.rect]

    %{
      kind: :terminal_prompt_footer_layout,
      layout: %{
        mode: :terminal_stack,
        region: :bottom_controls,
        order: 90,
        rect: Layout.bounding_rect(rects),
        regions: %{
          task_prompt: prompt.layout.rect,
          queued_notifications: queue.layout.rect,
          footer_state: footer.layout.rect
        }
      },
      prompt: prompt,
      queued_notifications: queue,
      footer: footer,
      stable_bottom_region?: stable_bottom_region?([prompt, queue, footer]),
      overlaps?: Layout.any_overlaps?(rects)
    }
  end

  @doc """
  Renders the bottom control stack as terminal-safe text.
  """
  @spec render_text(rendered_layout() | map()) :: String.t()
  def render_text(%{kind: :terminal_prompt_footer_layout} = layout) do
    [
      PromptInputArea.render_text(layout.prompt),
      "",
      QueuedNotificationArea.render_text(layout.queued_notifications),
      "",
      FooterStateArea.render_text(layout.footer)
    ]
    |> Enum.join("\n")
  end

  def render_text(startup_result) when is_map(startup_result) do
    startup_result
    |> render()
    |> render_text()
  end

  defp stable_bottom_region?(areas) do
    areas
    |> Enum.map(& &1.layout)
    |> Enum.all?(fn
      %{mode: mode, rect: %{x: x, y: y, width: width, height: height}}
      when mode in [:compact, :terminal_stack] and x == 0 and y >= 0 and width > 0 and
             height > 0 ->
        true

      _layout ->
        false
    end)
  end
end
