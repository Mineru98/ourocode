defmodule Ourocode.Terminal.QueuedNotificationArea do
  @moduledoc """
  Terminal-native queued notification area projection.

  The runtime owns queued notification state; this module only projects the
  pending items into a stable, terminal-safe pane frame that can be replayed
  from journaled state.
  """

  alias Ourocode.Terminal.{
    LayoutSegment,
    QueuedNotificationFields,
    QueuedNotificationItems,
    QueuedNotificationLayout,
    QueuedNotificationState
  }

  @type notification :: map()

  @type rendered_area :: %{
          required(:kind) => :queued_notification_area,
          required(:layout) => map(),
          required(:pending_count) => non_neg_integer(),
          required(:visible_count) => non_neg_integer(),
          required(:overflow_count) => non_neg_integer(),
          required(:overflow_policy) => atom() | String.t() | nil,
          required(:replayable?) => boolean(),
          required(:items) => [map()]
        }

  @doc """
  Builds a render-ready queued notification area from runtime queue state.
  """
  @spec render(map()) :: rendered_area()
  def render(%{queued_notifications: queued_notifications}) when is_map(queued_notifications) do
    render(queued_notifications)
  end

  def render(queue_state) when is_map(queue_state) do
    items =
      queue_state
      |> QueuedNotificationState.items()
      |> QueuedNotificationItems.pending_items()
      |> Enum.map(&QueuedNotificationItems.render_item/1)

    layout = QueuedNotificationLayout.build(queue_state)
    max_item_lines = QueuedNotificationLayout.max_item_lines(layout.rect)
    {visible_items, overflow_count} = visible_items(items, max_item_lines)

    %{
      kind: :queued_notification_area,
      layout: layout,
      pending_count: length(items),
      visible_count: length(visible_items),
      overflow_count: overflow_count,
      overflow_policy: value(queue_state, :overflow_policy),
      replayable?: value(queue_state, :replayable?) || false,
      items: visible_items
    }
  end

  @doc """
  Renders queued notifications as terminal-safe text.
  """
  @spec render_text(rendered_area() | map()) :: String.t()
  def render_text(%{kind: :queued_notification_area} = area) do
    [
      "+-- Queued Notifications (#{area.pending_count}) #{LayoutSegment.format(area, "queued_notifications")}",
      metadata_line(area)
      | item_lines(area.items)
    ]
    |> Kernel.++(["+--"])
    |> Enum.join("\n")
  end

  def render_text(queue_state) when is_map(queue_state) do
    queue_state
    |> render()
    |> render_text()
  end

  defp item_lines([]), do: ["| empty"]

  defp item_lines(items) do
    Enum.map(items, fn item ->
      [
        "| pending",
        "id=#{item.id}",
        "source=#{item.source}",
        maybe_segment("target", item.target),
        "priority=#{item.priority}",
        maybe_segment("seq", item.event_seq),
        maybe_segment("queued_at_ms", item.queued_at_ms),
        ~s(summary="#{escape_text(item.summary)}")
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end)
  end

  defp metadata_line(area) do
    "| policy=#{area.overflow_policy || :unknown} replayable?=#{area.replayable?}" <>
      overflow_segment(area)
  end

  defp visible_items(items, max_item_lines) when length(items) <= max_item_lines do
    {items, 0}
  end

  defp visible_items(items, max_item_lines) do
    overflow_count = length(items) - max_item_lines + 1
    overflow_item = QueuedNotificationItems.overflow_item(overflow_count)

    items
    |> Enum.take(max(max_item_lines - 1, 0))
    |> Kernel.++([overflow_item])
    |> then(&{&1, overflow_count})
  end

  defp overflow_segment(%{overflow_count: 0}), do: ""
  defp overflow_segment(%{overflow_count: count}), do: " overflow=#{count}"
  defp overflow_segment(_area), do: ""

  defp maybe_segment(_key, nil), do: ""
  defp maybe_segment(key, value), do: "#{key}=#{value}"

  defp value(map, key), do: QueuedNotificationFields.value(map, key)

  defp escape_text(text) do
    String.replace(text, ~s("), ~s(\\"))
  end
end
