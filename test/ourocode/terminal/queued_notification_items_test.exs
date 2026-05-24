defmodule Ourocode.Terminal.QueuedNotificationItemsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.QueuedNotificationItems

  test "filters only pending or queued notification records" do
    items = [
      %{id: "implicit"},
      %{id: "pending", status: :pending},
      %{"id" => "queued", "status" => "queued"},
      %{id: "delivered", status: :delivered}
    ]

    assert items
           |> QueuedNotificationItems.pending_items()
           |> Enum.map(&QueuedNotificationItems.render_item/1)
           |> Enum.map(& &1.id) == [
             "implicit",
             "pending",
             "queued"
           ]
  end

  test "renders terminal-safe item rows from aliases and payload summaries" do
    assert QueuedNotificationItems.render_item(%{
             notification_id: "notif-1",
             owner: :hook_lifecycle,
             pane_id: "child-pane-1",
             priority: :high,
             event_seq: 42,
             occurred_at_ms: 1_000,
             payload: %{"message" => "Hook started\nwaiting"}
           }) == %{
             id: "notif-1",
             source: "hook_lifecycle",
             target: "child-pane-1",
             priority: :high,
             summary: "Hook started waiting",
             event_seq: 42,
             queued_at_ms: 1_000
           }
  end

  test "builds bounded-layout overflow items" do
    assert QueuedNotificationItems.overflow_item(3).summary ==
             "3 additional queued notification(s) hidden by bounded layout"
  end
end
