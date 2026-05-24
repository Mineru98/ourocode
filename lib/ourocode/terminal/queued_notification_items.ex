defmodule Ourocode.Terminal.QueuedNotificationItems do
  @moduledoc """
  Projects queued notification records into terminal-safe item rows.
  """

  alias Ourocode.Terminal.QueuedNotificationFields

  @spec pending_items([term()]) :: [map()]
  def pending_items(items) when is_list(items), do: Enum.filter(items, &pending?/1)
  def pending_items(_items), do: []

  @spec render_item(term()) :: map()
  def render_item(item) when is_map(item) do
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

  @spec overflow_item(non_neg_integer()) :: map()
  def overflow_item(count) do
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

  defp pending?(item) when is_map(item) do
    status = value(item, :status)
    status in [nil, :pending, "pending", :queued, "queued"]
  end

  defp pending?(_item), do: false

  defp summary(item) do
    payload = item |> value(:payload) |> payload_summary()

    text_value(item, :summary) ||
      text_value(item, :message) ||
      text_value(item, :title) ||
      payload ||
      "pending notification"
  end

  defp payload_summary(payload) when is_binary(payload), do: terminal_safe(payload)

  defp payload_summary(payload) when is_map(payload) do
    text_value(payload, :summary) ||
      text_value(payload, :message) ||
      text_value(payload, :token) ||
      text_value(payload, :delta)
  end

  defp payload_summary(_payload), do: nil

  defp text_value(map, key), do: QueuedNotificationFields.text(map, key)
  defp value(map, key), do: QueuedNotificationFields.value(map, key)
  defp terminal_safe(text), do: QueuedNotificationFields.terminal_safe(text)
end
