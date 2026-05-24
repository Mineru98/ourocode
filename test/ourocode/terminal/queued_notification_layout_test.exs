defmodule Ourocode.Terminal.QueuedNotificationLayoutTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.QueuedNotificationLayout

  test "builds default bounded terminal stack layout" do
    assert QueuedNotificationLayout.build(%{}) == %{
             mode: :terminal_stack,
             region: :queued_notifications,
             bounded?: true,
             rect: %{x: 0, y: 26, width: 80, height: 6}
           }
  end

  test "bounds supplied rect values" do
    layout =
      QueuedNotificationLayout.build(%{
        layout: %{rect: %{x: -1, y: 20, width: 100, height: 20}}
      })

    assert layout.rect == %{x: 0, y: 20, width: 100, height: 6}
  end

  test "calculates visible item lines from reserved frame lines" do
    assert QueuedNotificationLayout.max_item_lines(%{height: 6}) == 3
    assert QueuedNotificationLayout.max_item_lines(%{height: 3}) == 1
  end
end
