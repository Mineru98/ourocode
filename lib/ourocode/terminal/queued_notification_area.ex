defmodule Ourocode.Terminal.QueuedNotificationArea do
  @moduledoc """
  Terminal-native queued notification area projection.

  The runtime owns queued notification state; this module only projects the
  pending items into a stable, terminal-safe pane frame that can be replayed
  from journaled state.
  """

  @type notification :: map()
  @default_width 80
  @default_height 6
  @default_y 26
  @reserved_frame_lines 3

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
      |> queue_items()
      |> pending_items()
      |> Enum.map(&render_item/1)

    layout = layout(queue_state)
    max_item_lines = max_item_lines(layout.rect)
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
      "+-- Queued Notifications (#{area.pending_count}) #{layout_segment(area)}",
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

  defp queue_items(queue_state) do
    case value(queue_state, :items) do
      items when is_list(items) -> items
      _items -> []
    end
  end

  defp pending_items(items) when is_list(items) do
    Enum.filter(items, &pending?/1)
  end

  defp pending_items(_items), do: []

  defp pending?(item) when is_map(item) do
    status = value(item, :status)
    status in [nil, :pending, "pending", :queued, "queued"]
  end

  defp pending?(_item), do: false

  defp render_item(item) do
    %{
      id: text_value(item, :id) || text_value(item, :notification_id) || "notification",
      source: text_value(item, :source) || text_value(item, :owner) || "runtime",
      target:
        text_value(item, :target) || text_value(item, :pane_id) || text_value(item, :session_id),
      priority: value(item, :priority) || :normal,
      summary: summary(item),
      event_seq: value(item, :event_seq),
      queued_at_ms: value(item, :queued_at_ms) || value(item, :occurred_at_ms)
    }
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

  defp layout_segment(%{layout: %{rect: rect, region: region}}) do
    "region=#{region} x=#{rect.x} y=#{rect.y} w=#{rect.width} h=#{rect.height}"
  end

  defp layout_segment(_area), do: "region=queued_notifications"

  defp layout(queue_state) do
    rect =
      queue_state
      |> value(:layout)
      |> rect_from_layout()
      |> bounded_rect()

    %{
      mode: :terminal_stack,
      region: :queued_notifications,
      bounded?: true,
      rect: rect
    }
  end

  defp rect_from_layout(%{rect: rect}) when is_map(rect), do: rect
  defp rect_from_layout(%{"rect" => rect}) when is_map(rect), do: rect
  defp rect_from_layout(rect) when is_map(rect), do: rect
  defp rect_from_layout(_layout), do: %{}

  defp bounded_rect(rect) do
    %{
      x: bounded_non_negative(rect_value(rect, :x), 0),
      y: bounded_non_negative(rect_value(rect, :y), @default_y),
      width: bounded_positive(rect_value(rect, :width), @default_width),
      height:
        rect
        |> rect_value(:height)
        |> bounded_positive(@default_height)
        |> max(@reserved_frame_lines + 1)
        |> min(@default_height)
    }
  end

  defp rect_value(rect, key) do
    Map.get(rect, key) || Map.get(rect, Atom.to_string(key))
  end

  defp bounded_non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp bounded_non_negative(_value, default), do: default

  defp bounded_positive(value, _default) when is_integer(value) and value > 0, do: value
  defp bounded_positive(_value, default), do: default

  defp max_item_lines(%{height: height}) when height > @reserved_frame_lines do
    height - @reserved_frame_lines
  end

  defp max_item_lines(_rect), do: 1

  defp visible_items(items, max_item_lines) when length(items) <= max_item_lines do
    {items, 0}
  end

  defp visible_items(items, max_item_lines) do
    overflow_count = length(items) - max_item_lines + 1
    overflow_item = overflow_item(overflow_count)

    items
    |> Enum.take(max(max_item_lines - 1, 0))
    |> Kernel.++([overflow_item])
    |> then(&{&1, overflow_count})
  end

  defp overflow_item(count) do
    %{
      id: "overflow",
      source: "runtime",
      target: nil,
      priority: :normal,
      summary: "#{count} additional queued notification(s) hidden by bounded layout",
      event_seq: nil,
      queued_at_ms: nil
    }
  end

  defp overflow_segment(%{overflow_count: 0}), do: ""
  defp overflow_segment(%{overflow_count: count}), do: " overflow=#{count}"
  defp overflow_segment(_area), do: ""

  defp summary(item) do
    payload = item |> value(:payload) |> payload_summary()

    text_value(item, :summary) ||
      text_value(item, :message) ||
      text_value(item, :title) ||
      payload ||
      "pending notification"
  end

  defp payload_summary(payload) when is_binary(payload), do: payload

  defp payload_summary(payload) when is_map(payload) do
    text_value(payload, :summary) ||
      text_value(payload, :message) ||
      text_value(payload, :token) ||
      text_value(payload, :delta)
  end

  defp payload_summary(_payload), do: nil

  defp maybe_segment(_key, nil), do: ""
  defp maybe_segment(key, value), do: "#{key}=#{value}"

  defp text_value(map, key) do
    case value(map, key) do
      value when is_binary(value) -> terminal_safe(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp terminal_safe(text) do
    text
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.trim()
  end

  defp escape_text(text) do
    String.replace(text, ~s("), ~s(\\"))
  end
end
