defmodule Ourocode.Runtime.SessionSettingsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.SessionSettings
  alias Ourocode.Runtime.Stream.Session

  test "normalizes valid session configuration from string and atom keys" do
    assert {:ok, settings} =
             SessionSettings.normalize(%{
               "runtime-source" => " ouroboros ",
               "session-id" => " session-123 ",
               "transport" => "streamable-http",
               "external-ids" => %{
                 :session_id => "native-session-123",
                 "thread_id" => "thread-1",
                 "attempt" => 2
               },
               "stream-cursor" => %{"event_seq" => 42},
               "stream-mailbox-capacity" => 128,
               "stream-mailbox-overflow-path" => "notify",
               "stream-mailbox-backpressure-threshold" => 64,
               "stream-mailbox-backpressure-behavior" => "delay",
               "stream-mailbox-backpressure-delay-ms" => 25,
               "stale-cleanup-timeout-ms" => 45_000,
               "operation-timeout-ms" => 90_000,
               "stream-subscription-cleanup-timeout-ms" => 12_000,
               "stream-mailbox-drain-interval-ms" => "manual",
               "stream-cleanup-action" => "mark-stale"
             })

    assert settings[:runtime_source] == "ouroboros"
    assert settings[:session_id] == "session-123"
    assert settings[:transport] == :streamable_http

    assert settings[:external_ids] == %{
             "session_id" => "native-session-123",
             "thread_id" => "thread-1",
             "attempt" => 2
           }

    assert settings[:stream_cursor] == %{"event_seq" => 42}
    assert settings[:stream_mailbox_capacity] == 128
    assert settings[:stream_mailbox_overflow_path] == :notify
    assert settings[:stream_mailbox_backpressure_threshold] == 64
    assert settings[:stream_mailbox_backpressure_behavior] == :delay
    assert settings[:stream_mailbox_backpressure_delay_ms] == 25
    assert settings[:stale_cleanup_timeout_ms] == 45_000
    assert settings[:operation_timeout_ms] == 90_000
    assert settings[:stream_subscription_cleanup_timeout_ms] == 12_000
    assert settings[:stream_mailbox_drain_interval_ms] == :manual
    assert settings[:stream_cleanup_action] == :mark_stale
  end

  test "rejects invalid session configuration with actionable errors" do
    invalid_settings = [
      {%{"runtime_source" => ""}, "runtime_source must be a non-empty string"},
      {%{"session_id" => 123}, "session_id must be a non-empty string"},
      {%{"transport" => "websocket"}, "transport must be one of stdio, sse, streamable_http"},
      {%{"external_ids" => []}, "external_ids must be a map"},
      {%{"external_ids" => %{"" => "bad"}}, "external_ids keys must be non-empty strings"},
      {%{"external_ids" => %{"session_id" => %{}}},
       "external_ids.session_id must be a string, number, boolean, or nil"},
      {%{"stream_cursor" => []}, "stream_cursor must be a map"},
      {%{"stream_mailbox_capacity" => 0}, "stream_mailbox_capacity must be a positive integer"},
      {%{"stream_mailbox_overflow_path" => "raise"},
       "stream_mailbox_overflow_path must be one of drop, notify"},
      {%{"stream_mailbox_backpressure_behavior" => "drop"},
       "stream_mailbox_backpressure_behavior must be one of none, notify, delay"},
      {%{"stream_mailbox_drain_interval_ms" => -1},
       "stream_mailbox_drain_interval_ms must be a non-negative integer or manual"},
      {%{"stream_cleanup_action" => "delete"},
       "stream_cleanup_action must be one of stop, mark_stale"},
      {%{"stream_mailbox_capacity" => 4, "stream_mailbox_backpressure_threshold" => 5},
       "stream_mailbox_backpressure_threshold must be less than or equal to stream_mailbox_capacity"}
    ]

    for {settings, expected_message} <- invalid_settings do
      assert {:error, {:invalid_session_settings, message}} = SessionSettings.normalize(settings)
      assert message =~ expected_message
    end
  end

  test "session stream accepts normalized valid session settings" do
    assert {:ok, pid} =
             Session.start_link(
               runtime_source: "synthetic",
               session_id: "session-settings-valid-1",
               transport: "stdio",
               external_ids: %{"session_id" => "session-settings-valid-1"},
               stream_cursor: %{"event_seq" => 7},
               stream_mailbox_capacity: 8,
               stream_mailbox_backpressure_threshold: 4,
               stream_mailbox_drain_interval_ms: :manual
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    assert %{
             stream_kind: :session,
             runtime_source: "synthetic",
             session_id: "session-settings-valid-1",
             transport: :stdio,
             external_ids: %{"session_id" => "session-settings-valid-1"},
             stream_cursor: %{"event_seq" => 7},
             stream_mailbox_capacity: 8,
             stream_mailbox_backpressure_threshold: 4
           } = Session.snapshot(pid)
  end

  test "session stream rejects invalid session settings before state is started" do
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error,
              {:invalid_session_settings,
               "stream_mailbox_backpressure_threshold must be less than or equal to stream_mailbox_capacity"}} =
               Session.start_link(
                 session_id: "session-settings-invalid-1",
                 stream_mailbox_capacity: 2,
                 stream_mailbox_backpressure_threshold: 3
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
    end
  end
end
