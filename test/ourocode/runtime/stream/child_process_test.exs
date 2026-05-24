defmodule Ourocode.Runtime.Stream.ChildProcessTest do
  use ExUnit.Case, async: false

  alias Ourocode.Runtime.Stream.Child
  alias Ourocode.Runtime.Stream.Telemetry

  setup do
    original_stream_mailbox_capacity = Application.get_env(:ourocode, :stream_mailbox_capacity)

    original_stream_mailbox_overflow_path =
      Application.get_env(:ourocode, :stream_mailbox_overflow_path)

    on_exit(fn ->
      restore_env(:stream_mailbox_capacity, original_stream_mailbox_capacity)
      restore_env(:stream_mailbox_overflow_path, original_stream_mailbox_overflow_path)
    end)
  end

  test "mailbox capacity is enforced from config and overflow path is triggered" do
    Application.put_env(:ourocode, :stream_mailbox_capacity, 2)
    Application.put_env(:ourocode, :stream_mailbox_overflow_path, :notify)

    child_pid =
      start_child!(
        child_id: "child-mailbox-1",
        parent_call_id: "parent-mailbox-1",
        runtime_source: "synthetic",
        transport: :stdio,
        stream_mailbox_overflow_target: self(),
        stream_mailbox_drain_interval_ms: :manual
      )

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-mailbox-1",
               parent_call_id: "parent-mailbox-1"
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 2,
               child_id: "child-mailbox-1",
               parent_call_id: "parent-mailbox-1"
             })

    assert {:error,
            %{
              overflow_path: :notify,
              overflow_behavior: :drop_newest,
              stream_kind: :child,
              event_seq: 3,
              dropped_event_seq: 3,
              capacity: 2,
              retained_pending_count: 2
            }} =
             Child.record_event(child_pid, %{
               event_seq: 3,
               child_id: "child-mailbox-1",
               parent_call_id: "parent-mailbox-1"
             })

    assert_receive {:stream_mailbox_overflow,
                    %{
                      overflow_path: :notify,
                      overflow_behavior: :drop_newest,
                      stream_kind: :child,
                      event_seq: 3,
                      dropped_event_seq: 3,
                      capacity: 2,
                      retained_pending_count: 2
                    }}

    assert %{
             event_count: 0,
             stream_mailbox_capacity: 2,
             stream_mailbox_pending_count: 2,
             stream_mailbox_overflow_count: 1
           } = Child.snapshot(child_pid)
  end

  test "mailbox overflow drops newest event and drains retained events in order" do
    child_pid =
      start_child!(
        child_id: "child-mailbox-drop-newest-1",
        parent_call_id: "parent-mailbox-drop-newest-1",
        runtime_source: "synthetic",
        transport: :stdio,
        stream_mailbox_capacity: 2,
        stream_mailbox_overflow_path: :drop,
        stream_mailbox_drain_interval_ms: :manual
      )

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-mailbox-drop-newest-1",
               parent_call_id: "parent-mailbox-drop-newest-1",
               transport: :stdio
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 2,
               child_id: "child-mailbox-drop-newest-1",
               parent_call_id: "parent-mailbox-drop-newest-1",
               transport: :stdio
             })

    assert {:error,
            %{
              overflow_path: :drop,
              overflow_behavior: :drop_newest,
              stream_kind: :child,
              event_seq: 3,
              dropped_event_seq: 3,
              capacity: 2,
              retained_pending_count: 2
            }} =
             Child.record_event(child_pid, %{
               event_seq: 3,
               child_id: "child-mailbox-drop-newest-1",
               parent_call_id: "parent-mailbox-drop-newest-1",
               transport: :stdio
             })

    refute_receive {:stream_mailbox_overflow, _overflow}, 20

    send(child_pid, :drain_stream_mailbox)

    assert %{
             event_count: 1,
             stream_mailbox_pending_count: 1,
             stream_mailbox_overflow_count: 1,
             stream_cursor: %{event_seq: 1}
           } = Child.snapshot(child_pid)

    send(child_pid, :drain_stream_mailbox)

    assert %{
             event_count: 2,
             stream_mailbox_pending_count: 0,
             stream_mailbox_overflow_count: 1,
             stream_cursor: %{event_seq: 2}
           } = Child.snapshot(child_pid)

    send(child_pid, :drain_stream_mailbox)

    assert %{
             event_count: 2,
             stream_mailbox_pending_count: 0,
             stream_mailbox_overflow_count: 1,
             stream_cursor: %{event_seq: 2}
           } = Child.snapshot(child_pid)
  end

  test "mailbox backpressure notifies producer before overflow threshold is reached" do
    child_pid =
      start_child!(
        child_id: "child-mailbox-backpressure-notify-1",
        parent_call_id: "parent-mailbox-backpressure-notify-1",
        runtime_source: "synthetic",
        transport: :stdio,
        stream_mailbox_capacity: 4,
        stream_mailbox_backpressure_threshold: 2,
        stream_mailbox_backpressure_behavior: :notify,
        stream_mailbox_backpressure_target: self(),
        stream_mailbox_drain_interval_ms: :manual
      )

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-mailbox-backpressure-notify-1",
               parent_call_id: "parent-mailbox-backpressure-notify-1"
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 2,
               child_id: "child-mailbox-backpressure-notify-1",
               parent_call_id: "parent-mailbox-backpressure-notify-1"
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 3,
               child_id: "child-mailbox-backpressure-notify-1",
               parent_call_id: "parent-mailbox-backpressure-notify-1"
             })

    assert_receive {:stream_mailbox_backpressure,
                    %{
                      backpressure_behavior: :notify,
                      stream_kind: :child,
                      event_seq: 3,
                      threshold: 2,
                      capacity: 4,
                      pending_count: 2,
                      delay_ms: 0
                    }}

    assert %{
             event_count: 0,
             stream_mailbox_capacity: 4,
             stream_mailbox_pending_count: 3,
             stream_mailbox_backpressure_count: 1,
             stream_mailbox_overflow_count: 0
           } = Child.snapshot(child_pid)
  end

  test "mailbox backpressure delays synchronous producers after threshold is exceeded" do
    delay_ms = 40

    child_pid =
      start_child!(
        child_id: "child-mailbox-backpressure-delay-1",
        parent_call_id: "parent-mailbox-backpressure-delay-1",
        runtime_source: "synthetic",
        transport: :stdio,
        stream_mailbox_capacity: 4,
        stream_mailbox_backpressure_threshold: 1,
        stream_mailbox_backpressure_behavior: :delay,
        stream_mailbox_backpressure_delay_ms: delay_ms,
        stream_mailbox_backpressure_target: self(),
        stream_mailbox_drain_interval_ms: :manual
      )

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-mailbox-backpressure-delay-1",
               parent_call_id: "parent-mailbox-backpressure-delay-1"
             })

    started_at = System.monotonic_time(:millisecond)

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 2,
               child_id: "child-mailbox-backpressure-delay-1",
               parent_call_id: "parent-mailbox-backpressure-delay-1"
             })

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert elapsed_ms >= delay_ms

    assert_receive {:stream_mailbox_backpressure,
                    %{
                      backpressure_behavior: :delay,
                      stream_kind: :child,
                      event_seq: 2,
                      threshold: 1,
                      capacity: 4,
                      pending_count: 1,
                      delay_ms: ^delay_ms
                    }}

    assert %{
             event_count: 0,
             stream_mailbox_pending_count: 2,
             stream_mailbox_backpressure_count: 1,
             stream_mailbox_overflow_count: 0
           } = Child.snapshot(child_pid)
  end

  test "backpressure emits telemetry when detected and relieved with queue metadata" do
    attach_stream_backpressure_telemetry_handler()

    child_pid =
      start_child!(
        child_id: "child-mailbox-backpressure-telemetry-1",
        parent_call_id: "parent-mailbox-backpressure-telemetry-1",
        runtime_source: "synthetic",
        transport: :sse,
        external_ids: %{"session_id" => "session-backpressure-telemetry-1"},
        stream_mailbox_capacity: 4,
        stream_mailbox_backpressure_threshold: 2,
        stream_mailbox_backpressure_behavior: :notify,
        stream_mailbox_backpressure_target: self(),
        stream_mailbox_drain_interval_ms: :manual
      )

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 1,
               child_id: "child-mailbox-backpressure-telemetry-1",
               parent_call_id: "parent-mailbox-backpressure-telemetry-1",
               transport: :sse
             })

    refute_receive {:telemetry_event, [:ourocode, :runtime, :stream, :backpressure, :detected], _,
                    _},
                   20

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 2,
               child_id: "child-mailbox-backpressure-telemetry-1",
               parent_call_id: "parent-mailbox-backpressure-telemetry-1",
               transport: :sse
             })

    assert :ok =
             Child.record_event(child_pid, %{
               event_seq: 3,
               child_id: "child-mailbox-backpressure-telemetry-1",
               parent_call_id: "parent-mailbox-backpressure-telemetry-1",
               transport: :sse
             })

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :backpressure, :detected],
                    detected_measurements,
                    %{
                      pressure_state: :detected,
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :sse,
                      parent_call_id: "parent-mailbox-backpressure-telemetry-1",
                      child_id: "child-mailbox-backpressure-telemetry-1",
                      external_ids: %{"session_id" => "session-backpressure-telemetry-1"},
                      event_seq: 3,
                      queue_depth: 2,
                      pending_count: 2,
                      threshold: 2,
                      capacity: 4,
                      delay_ms: 0,
                      stream_mailbox_pending_count: 2,
                      stream_mailbox_capacity: 4,
                      stream_mailbox_backpressure_threshold: 2,
                      stream_mailbox_backpressure_behavior: :notify,
                      pid: ^child_pid
                    }},
                   250

    assert detected_measurements.queue_depth == 2
    assert detected_measurements.threshold == 2
    assert detected_measurements.capacity == 4

    assert_receive {:stream_mailbox_backpressure,
                    %{
                      backpressure_behavior: :notify,
                      stream_kind: :child,
                      event_seq: 3,
                      threshold: 2,
                      capacity: 4,
                      pending_count: 2,
                      delay_ms: 0
                    }},
                   250

    assert %{
             stream_mailbox_pending_count: 3,
             stream_mailbox_backpressure_count: 1,
             stream_mailbox_backpressure_active?: true
           } = Child.snapshot(child_pid)

    send(child_pid, :drain_stream_mailbox)

    refute_receive {:telemetry_event, [:ourocode, :runtime, :stream, :backpressure, :relieved], _,
                    _},
                   20

    send(child_pid, :drain_stream_mailbox)

    assert_receive {:telemetry_event, [:ourocode, :runtime, :stream, :backpressure, :relieved],
                    relieved_measurements,
                    %{
                      pressure_state: :relieved,
                      stream_kind: :child,
                      runtime_source: "synthetic",
                      transport: :sse,
                      parent_call_id: "parent-mailbox-backpressure-telemetry-1",
                      child_id: "child-mailbox-backpressure-telemetry-1",
                      external_ids: %{"session_id" => "session-backpressure-telemetry-1"},
                      event_seq: 2,
                      queue_depth: 1,
                      pending_count: 1,
                      previous_pending_count: 2,
                      threshold: 2,
                      capacity: 4,
                      delay_ms: 0,
                      stream_mailbox_pending_count: 1,
                      stream_mailbox_capacity: 4,
                      stream_mailbox_backpressure_threshold: 2,
                      stream_mailbox_backpressure_behavior: :notify,
                      pid: ^child_pid
                    }},
                   250

    assert relieved_measurements.queue_depth == 1
    assert relieved_measurements.threshold == 2
    assert relieved_measurements.capacity == 4

    assert %{
             event_count: 2,
             stream_mailbox_pending_count: 1,
             stream_mailbox_backpressure_count: 1,
             stream_mailbox_backpressure_active?: false,
             stream_cursor: %{event_seq: 2}
           } = Child.snapshot(child_pid)
  end

  defp start_child!(opts) do
    assert {:ok, pid} = Child.start_link(opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp attach_stream_backpressure_telemetry_handler do
    handler_id = {__MODULE__, self(), :backpressure, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [Telemetry.backpressure_detected_event(), Telemetry.backpressure_relieved_event()],
        fn event_name, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)
end
