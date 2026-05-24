defmodule Ourocode.Runtime.HookLifecycleTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.HookLifecycle

  test "applies hook lifecycle events and tracks latest event by type" do
    state = %{
      events: [%{type: :hook_started, token: "old"}],
      event_count: 1,
      latest_started: %{type: :hook_started, token: "old"},
      latest_progress: nil,
      latest_response: nil,
      latest_completed: nil
    }

    events = [
      %{type: :parent_call_event},
      %{type: :hook_started, token: "new-start"},
      %{"type" => :hook_progress, "token" => "progress"},
      %{type: :hook_response, token: "response"},
      %{type: :hook_completed, token: "done"}
    ]

    updated = HookLifecycle.apply_events(state, events)

    assert updated.event_count == 5

    assert Enum.map(updated.events, fn event ->
             Map.get(event, :token) || Map.get(event, "token")
           end) ==
             ["old", "new-start", "progress", "response", "done"]

    assert updated.latest_started == %{type: :hook_started, token: "new-start"}
    assert updated.latest_progress == %{"type" => :hook_progress, "token" => "progress"}
    assert updated.latest_response == %{type: :hook_response, token: "response"}
    assert updated.latest_completed == %{type: :hook_completed, token: "done"}
  end

  test "calculates latest event sequence from explicit or implicit sequence values" do
    assert HookLifecycle.latest_event_seq([], %{normalized_event_seq: 7}) == 7

    assert HookLifecycle.latest_event_seq(
             [%{type: :parent_call_event}, %{type: :hook_started}],
             %{normalized_event_seq: 7}
           ) == 9

    assert HookLifecycle.latest_event_seq(
             [%{event_seq: 4}, %{"event_seq" => 12}, %{event_seq: "ignored"}],
             %{normalized_event_seq: 7}
           ) == 12
  end
end
