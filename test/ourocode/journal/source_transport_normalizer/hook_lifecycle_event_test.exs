defmodule Ourocode.Journal.SourceTransportNormalizer.HookLifecycleEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal.SourceTransportNormalizer.HookLifecycleEvent
  alias Ourocode.MCP.LifecycleEvent

  test "normalizes hook progress maps with payload fallback fields" do
    assert {:ok, %LifecycleEvent{} = event} =
             HookLifecycleEvent.normalize(
               %{
                 "type" => "hook_progress",
                 "hook_id" => "hook-progress-1",
                 "source" => "plugin_runtime",
                 "timestamp_ms" => 123,
                 "payload" => %{
                   "state" => "manifest_loaded",
                   "ordering" => %{"phase" => 2}
                 }
               },
               context()
             )

    assert event.type == :hook_progress
    assert event.source == :plugin_runtime
    assert event.transport == :runtime
    assert event.progress_state == "manifest_loaded"
    assert event.ordering_metadata == %{"phase" => 2}
    assert event.event_seq == 7
    assert event.parent_call_id == "parent-hook"
    assert event.runtime_source == "plugin_runtime"
    assert event.external_ids == %{"session_id" => "session-hook"}
    assert event.occurred_at_ms == 123
  end

  test "normalizes hook response aliases with completion metadata" do
    error = %{"code" => "timeout"}

    assert {:ok, %LifecycleEvent{} = event} =
             HookLifecycleEvent.normalize(
               %{
                 type: :runtime_hook_response,
                 hook_id: "hook-response-1",
                 source: :runtime,
                 payload: %{
                   "error" => error,
                   "metadata" => %{"duration_ms" => 5_000}
                 }
               },
               context()
             )

    assert event.type == :hook_response
    assert event.status == :error
    assert event.result == nil
    assert event.error == error
    assert event.completion_metadata == %{"duration_ms" => 5_000}
  end

  test "rejects non-hook lifecycle maps" do
    assert HookLifecycleEvent.normalize(
             %{type: :not_a_hook, hook_id: "hook", source: :runtime},
             context()
           ) ==
             :error
  end

  defp context do
    %{
      event_seq: 7,
      parent_call_id: "parent-hook",
      runtime_source: "runtime-context",
      external_ids: %{"session_id" => "session-hook"}
    }
  end
end
