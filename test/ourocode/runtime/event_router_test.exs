defmodule Ourocode.Runtime.EventRouterTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.EventRouter

  test "route journals normalized events and updates event pipeline and hooks" do
    journal_path =
      Path.join(
        System.tmp_dir!(),
        "ourocode-event-router-#{System.unique_integer([:positive])}.jsonl"
      )

    {:ok, event_pipeline_pid} =
      Agent.start_link(fn ->
        %{
          normalized_event_seq: 0,
          normalized_event_count: 0,
          events: [],
          generic_log_messages: []
        }
      end)

    {:ok, hook_lifecycle_pid} =
      Agent.start_link(fn ->
        %{
          events: [],
          event_count: 0,
          latest_started: nil,
          latest_progress: nil,
          latest_response: nil,
          latest_completed: nil
        }
      end)

    runtime = %{
      services: %{event_pipeline: event_pipeline_pid, hook_lifecycle: hook_lifecycle_pid},
      journal: %{path: journal_path}
    }

    on_exit(fn ->
      if Process.alive?(event_pipeline_pid), do: Agent.stop(event_pipeline_pid)
      if Process.alive?(hook_lifecycle_pid), do: Agent.stop(hook_lifecycle_pid)
      File.rm(journal_path)
    end)

    source_event = %{
      "type" => "hook_started",
      "hook_id" => "hook-router-1",
      "source" => "hook_lifecycle",
      "timestamp_ms" => 91_001,
      "payload" => %{"hook" => "before_child_dispatch"}
    }

    assert {:ok, result} =
             EventRouter.route(runtime, source_event,
               parent_call_id: "parent-router-1",
               external_ids: %{"session_id" => "session-router-1"}
             )

    assert [%LifecycleEvent{} = event] = result.events
    assert event.type == :hook_started
    assert event.hook_id == "hook-router-1"
    assert event.parent_call_id == "parent-router-1"
    assert result.event_pipeline.events == [event]
    assert result.event_pipeline.normalized_event_count == 1
    assert result.hooks.latest_started == event

    assert {:ok, [journaled_event]} = Journal.read_ordered(journal_path)
    assert journaled_event.type == :hook_started
    assert journaled_event.hook_id == "hook-router-1"
  end

  test "route reports unavailable runtime event pipeline" do
    assert EventRouter.route(%{}, %{}) ==
             {:error, %{status: :failed, reason: :runtime_event_pipeline_unavailable}}
  end
end
