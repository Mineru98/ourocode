defmodule Ourocode.Terminal.FooterHookActivityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.FooterHookActivity

  test "summarizes active hook progress newer than completed hooks" do
    assert FooterHookActivity.from_states([
             %{
               hook_lifecycle: %{
                 event_count: 3,
                 latest_started: %{event_seq: 4, hook_id: "hook-started-1"},
                 latest_progress: %{
                   event_seq: 6,
                   hook_id: "hook-started-1",
                   payload: %{"hook" => "before_child_dispatch"}
                 },
                 latest_response: %{event_seq: 2, hook_id: "hook-older-1"}
               }
             }
           ]) == %{
             state: :running,
             summary: "Running before_child_dispatch hook",
             hook_id: "hook-started-1",
             hook_event: "before_child_dispatch",
             event_count: 3
           }
  end

  test "reports idle when completion is newer than start" do
    assert FooterHookActivity.from_states([
             %{
               hooks: %{
                 event_count: 5,
                 latest_started: %{event_seq: 4, hook_id: "hook-1"},
                 latest_completed: %{event_seq: 7, hook_id: "hook-1"}
               }
             }
           ]) == %{
             state: :idle,
             summary: "idle",
             hook_id: nil,
             hook_event: nil,
             event_count: 5
           }
  end

  test "counts events when explicit event count is absent" do
    assert FooterHookActivity.from_states([
             %{"hook_lifecycle" => %{"events" => [%{}, %{}, %{}]}}
           ]).event_count == 3
  end

  test "uses the first available state and truncates long hook names" do
    long_hook = String.duplicate("a", 80)

    activity =
      FooterHookActivity.from_states([
        %{},
        %{
          hook_lifecycle: %{
            latest_started: %{event_seq: 1, hook_id: "hook-1", payload: %{hook: long_hook}}
          }
        }
      ])

    assert activity.state == :running
    assert activity.hook_event == String.slice(long_hook, 0, 60)
  end
end
