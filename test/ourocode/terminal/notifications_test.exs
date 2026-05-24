defmodule Ourocode.Terminal.NotificationsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Notifications

  test "push prepends notifications and keeps the newest three" do
    state = %{notifications: []}

    state =
      state
      |> Notifications.push("one", 100, 50)
      |> Notifications.push("two", 110, 50)
      |> Notifications.push("three", 120, 50)
      |> Notifications.push("four", 130, 50)

    assert state.notifications == [
             {"four", 180},
             {"three", 170},
             {"two", 160}
           ]
  end

  test "active returns unexpired text and prunes stale notifications" do
    state = %{
      notifications: [
        {"new", 200},
        {"old", 100},
        {"also new", 180}
      ]
    }

    assert {["new", "also new"], state} = Notifications.active(state, 150)
    assert state.notifications == [{"new", 200}, {"also new", 180}]
  end

  test "clear removes all notifications" do
    assert %{notifications: []} = Notifications.clear(%{notifications: [{"one", 100}]})
  end
end
