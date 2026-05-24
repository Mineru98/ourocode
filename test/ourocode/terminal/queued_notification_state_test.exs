defmodule Ourocode.Terminal.QueuedNotificationStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.QueuedNotificationState

  test "finds queue state from startup result runtime first" do
    assert QueuedNotificationState.from_startup_result(%{
             runtime: %{queued_notifications: %{pending_count: 2}},
             context: %{queued_notifications: %{pending_count: 1}},
             queued_notifications: %{pending_count: 0}
           }) == %{pending_count: 2}
  end

  test "finds queue state from context runtime or direct context" do
    assert QueuedNotificationState.from_startup_result(%{
             context: %{runtime: %{queued_notifications: %{pending_count: 3}}}
           }) == %{pending_count: 3}

    assert QueuedNotificationState.from_startup_result(%{
             context: %{queued_notifications: %{pending_count: 4}}
           }) == %{pending_count: 4}
  end

  test "counts pending items when no pending_count is provided" do
    queue_state = %{
      items: [
        %{id: "implicit"},
        %{id: "queued", status: :queued},
        %{id: "delivered", status: :delivered}
      ]
    }

    assert QueuedNotificationState.pending_count(queue_state) == 2
  end

  test "returns empty defaults for missing or malformed queue state" do
    assert QueuedNotificationState.from_startup_result(%{}) == %{}
    assert QueuedNotificationState.pending_count(%{pending_count: -1}) == 0
    assert QueuedNotificationState.items(%{"items" => "bad"}) == []
  end
end
