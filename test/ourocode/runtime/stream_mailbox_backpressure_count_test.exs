defmodule Ourocode.Runtime.StreamMailboxBackpressureCountTest do
  use ExUnit.Case, async: false

  alias Ourocode.Runtime.Stream.Child

  test "event buffering preserves produced normalized event count under backpressure" do
    produced_events =
      for seq <- 1..24 do
        %{
          type: :parent_call_event,
          event_seq: seq,
          child_id: "child-backpressure-count-1",
          parent_call_id: "parent-backpressure-count-1",
          runtime_source: "synthetic",
          transport: :stdio,
          token: "token-#{seq}",
          external_ids: %{"session_id" => "session-backpressure-count-1"}
        }
      end

    {:ok, child_pid} =
      Child.start_link(
        child_id: "child-backpressure-count-1",
        parent_call_id: "parent-backpressure-count-1",
        runtime_source: "synthetic",
        transport: :stdio,
        external_ids: %{"session_id" => "session-backpressure-count-1"},
        stream_mailbox_capacity: length(produced_events),
        stream_mailbox_backpressure_threshold: 4,
        stream_mailbox_backpressure_behavior: :notify,
        stream_mailbox_backpressure_target: self(),
        stream_mailbox_drain_interval_ms: :manual
      )

    on_exit(fn ->
      if Process.alive?(child_pid), do: GenServer.stop(child_pid)
    end)

    accepted_count =
      produced_events
      |> Enum.count(fn event -> Child.record_event(child_pid, event) == :ok end)

    assert accepted_count == length(produced_events)

    assert_receive {:stream_mailbox_backpressure,
                    %{
                      backpressure_behavior: :notify,
                      stream_kind: :child,
                      event_seq: 5,
                      threshold: 4,
                      capacity: 24,
                      pending_count: 4,
                      delay_ms: 0
                    }},
                   250

    assert %{
             event_count: 0,
             stream_mailbox_pending_count: buffered_count,
             stream_mailbox_overflow_count: 0,
             stream_mailbox_backpressure_count: backpressure_count,
             stream_mailbox_backpressure_active?: true
           } = Child.snapshot(child_pid)

    assert buffered_count == length(produced_events)
    assert buffered_count == accepted_count
    assert backpressure_count == length(produced_events) - 4
  end

  test "event buffering preserves exact produced sequence coverage under backpressure" do
    produced_events =
      for seq <- 1..32 do
        %{
          type: :parent_call_event,
          event_seq: seq,
          child_id: "child-backpressure-coverage-1",
          parent_call_id: "parent-backpressure-coverage-1",
          runtime_source: "synthetic",
          transport: :streamable_http,
          token: "token-#{seq}",
          external_ids: %{"session_id" => "session-backpressure-coverage-1"}
        }
      end

    {:ok, child_pid} =
      Child.start_link(
        child_id: "child-backpressure-coverage-1",
        parent_call_id: "parent-backpressure-coverage-1",
        runtime_source: "synthetic",
        transport: :streamable_http,
        external_ids: %{"session_id" => "session-backpressure-coverage-1"},
        stream_mailbox_capacity: length(produced_events),
        stream_mailbox_backpressure_threshold: 3,
        stream_mailbox_backpressure_behavior: :notify,
        stream_mailbox_backpressure_target: self(),
        stream_mailbox_drain_interval_ms: :manual,
        stream_mailbox_final_flush_target: self(),
        stream_mailbox_rendered_event_target: self()
      )

    on_exit(fn ->
      if Process.alive?(child_pid), do: GenServer.stop(child_pid)
    end)

    assert :ok = Child.begin_operation(child_pid, "op-backpressure-coverage-1")

    accepted_results = Enum.map(produced_events, &Child.record_event(child_pid, &1))
    assert accepted_results == List.duplicate(:ok, length(produced_events))

    produced_sequence_ids = Enum.map(produced_events, & &1.event_seq)

    assert %{
             event_count: 0,
             stream_mailbox_pending_count: 32,
             stream_mailbox_overflow_count: 0,
             stream_mailbox_backpressure_active?: true
           } = Child.snapshot(child_pid)

    assert :ok = Child.complete_operation(child_pid, "op-backpressure-coverage-1")

    rendered_sequence_ids =
      for _ <- produced_events do
        assert_receive {:stream_mailbox_rendered_event, %{event_seq: event_seq}}, 250
        event_seq
      end

    assert_receive {:stream_mailbox_final_flush,
                    %{
                      flushed_pending_count: 32,
                      rendered_event_seqs: buffered_sequence_ids,
                      pending_count: 0,
                      completion_status: :completed
                    }},
                   250

    assert rendered_sequence_ids == produced_sequence_ids
    assert buffered_sequence_ids == produced_sequence_ids
    assert Enum.frequencies(buffered_sequence_ids) == Map.new(produced_sequence_ids, &{&1, 1})

    assert %{
             event_count: 32,
             stream_mailbox_pending_count: 0,
             stream_mailbox_overflow_count: 0,
             stream_completion_status: :completed
           } = Child.snapshot(child_pid)
  end
end
