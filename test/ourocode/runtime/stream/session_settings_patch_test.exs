defmodule Ourocode.Runtime.Stream.SessionSettingsPatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Stream.SessionSettingsPatch

  test "normalizes patch aliases from string and atom keys" do
    assert SessionSettingsPatch.normalize_patch(%{
             "stream-mailbox-capacity" => 12,
             "stream_mailbox_backpressure_threshold" => 6,
             stale_cleanup_timeout_ms: 20_000
           }) ==
             {:ok,
              %{
                stream_mailbox_capacity: 12,
                stream_mailbox_backpressure_threshold: 6,
                stale_cleanup_timeout_ms: 20_000
              }}
  end

  test "rejects non-keyword list patches" do
    assert SessionSettingsPatch.normalize_patch([:not, :keyword]) ==
             {:error,
              {:invalid_session_settings, "session settings must be a map or keyword list"}}
  end

  test "builds a settings base from live session state" do
    state = base_state()

    assert SessionSettingsPatch.base(state) == %{
             runtime_source: "synthetic",
             session_id: "session-1",
             transport: :stdio,
             external_ids: %{"session_id" => "session-1"},
             stream_cursor: %{event_seq: 1},
             stream_mailbox_capacity: 8,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 4,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             stale_cleanup_timeout_ms: 30_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             stream_mailbox_drain_interval_ms: 0,
             stream_cleanup_action: :stop
           }
  end

  test "applies valid patches through session settings validation" do
    assert {:ok, state} =
             SessionSettingsPatch.apply(base_state(), %{
               "stream-mailbox-capacity" => 16,
               "stream-mailbox-backpressure-threshold" => 8,
               "stream-cleanup-action" => "mark-stale",
               "external-ids" => %{"session_id" => "session-2"},
               "stream-cursor" => %{event_seq: 2}
             })

    assert state.stream_mailbox_capacity == 16
    assert state.stream_mailbox_backpressure_threshold == 8
    assert state.stream_cleanup_action == :mark_stale
    assert state.external_ids == %{"session_id" => "session-2"}
    assert state.stream_cursor == %{event_seq: 2}
  end

  test "rejects patches that violate session setting bounds" do
    assert {:error,
            {:invalid_session_settings,
             "stream_mailbox_backpressure_threshold must be less than or equal to stream_mailbox_capacity"}} =
             SessionSettingsPatch.apply(base_state(), %{
               stream_mailbox_capacity: 2,
               stream_mailbox_backpressure_threshold: 4
             })
  end

  defp base_state do
    %{
      runtime_source: "synthetic",
      session_id: "session-1",
      transport: :stdio,
      external_ids: %{"session_id" => "session-1"},
      stream_cursor: %{event_seq: 1},
      stream_mailbox_capacity: 8,
      stream_mailbox_overflow_path: :drop,
      stream_mailbox_backpressure_threshold: 4,
      stream_mailbox_backpressure_behavior: :notify,
      stream_mailbox_backpressure_delay_ms: 10,
      stream_stale_cleanup_timeout_ms: 30_000,
      stream_operation_timeout_ms: 120_000,
      stream_subscription_cleanup_timeout_ms: 10_000,
      stream_mailbox_drain_interval_ms: 0,
      stream_cleanup_action: :stop
    }
  end
end
