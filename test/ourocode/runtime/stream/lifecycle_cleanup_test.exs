defmodule Ourocode.Runtime.Stream.LifecycleCleanupTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.Lifecycle
  alias Ourocode.Runtime.Stream.Mailbox

  test "idle timeout cleanup marks stale streams and releases registered resources" do
    parent = self()

    state =
      [
        stale_cleanup_timeout_ms: 1,
        stream_cleanup_action: :mark_stale,
        stream_cleanup_target: parent,
        stream_subscription_cleanup_timeout_ms: 50,
        stream_mailbox_drain_interval_ms: :manual,
        stream_now_ms: System.monotonic_time(:millisecond) - 100
      ]
      |> lifecycle_state()
      |> Map.update!(:stream_process_handles, &[{:port, "runtime-port-1"} | &1])
      |> Map.update!(
        :stream_subscriptions,
        &[{:unsubscribe, parent, :released_subscription} | &1]
      )
      |> Map.update!(:stream_registered_buffers, &[{:http_response, "partial-frame"} | &1])
      |> enqueue!(%{event_seq: 1})
      |> enqueue!(%{event_seq: 2})

    assert {:noreply, cleaned} =
             Lifecycle.handle_idle_timeout(state, state.stream_last_activity_monotonic_ms)

    assert cleaned.stream_status == :stale
    assert cleaned.stream_cleanup_reason == :idle_timeout
    assert cleaned.stream_mailbox_pending_count == 0
    assert cleaned.stream_process_handles == []
    assert cleaned.stream_subscriptions == []
    assert cleaned.stream_registered_buffers == []

    assert_received :released_subscription

    assert_receive {:stream_stale_cleanup,
                    %{
                      cleanup_reason: :idle_timeout,
                      stream_kind: :child,
                      child_id: "child-cleanup-1",
                      released_resources: %{
                        process_handles: 1,
                        subscriptions: 1,
                        registered_buffers: 1,
                        pending_events: 2
                      }
                    }}
  end

  defp lifecycle_state(opts) do
    %{
      stream_kind: :child,
      child_id: "child-cleanup-1",
      parent_call_id: "parent-cleanup-1",
      runtime_source: "synthetic",
      transport: :stdio,
      external_ids: %{"session_id" => "session-cleanup-1"},
      stream_cursor: %{child_id: "child-cleanup-1", parent_call_id: "parent-cleanup-1"},
      event_count: 0
    }
    |> Map.merge(Mailbox.fields(opts))
    |> Map.merge(Lifecycle.fields(opts))
  end

  defp enqueue!(state, event) do
    {:ok, state} = Mailbox.enqueue(state, event)
    state
  end
end
