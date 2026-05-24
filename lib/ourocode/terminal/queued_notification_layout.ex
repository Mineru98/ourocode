defmodule Ourocode.Terminal.QueuedNotificationLayout do
  @moduledoc """
  Layout projection for the bounded queued notification terminal area.
  """

  alias Ourocode.Terminal.QueuedNotificationFields

  @default_width 80
  @default_height 6
  @default_y 26
  @reserved_frame_lines 3

  @spec build(map()) :: map()
  def build(queue_state) when is_map(queue_state) do
    rect =
      queue_state
      |> QueuedNotificationFields.value(:layout)
      |> rect_from_layout()
      |> bounded_rect()

    %{
      mode: :terminal_stack,
      region: :queued_notifications,
      bounded?: true,
      rect: rect
    }
  end

  @spec max_item_lines(map()) :: pos_integer()
  def max_item_lines(%{height: height}) when height > @reserved_frame_lines do
    height - @reserved_frame_lines
  end

  def max_item_lines(_rect), do: 1

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

  defp rect_value(rect, key), do: QueuedNotificationFields.value(rect, key)

  defp bounded_non_negative(value, _default) when is_integer(value) and value >= 0, do: value
  defp bounded_non_negative(_value, default), do: default

  defp bounded_positive(value, _default) when is_integer(value) and value > 0, do: value
  defp bounded_positive(_value, default), do: default
end
