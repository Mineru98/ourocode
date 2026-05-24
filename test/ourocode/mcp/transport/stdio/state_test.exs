defmodule Ourocode.MCP.Transport.Stdio.StateTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Stdio
  alias Ourocode.MCP.Transport.Stdio.State

  test "builds initial transport state with explicit options" do
    state =
      State.build(
        :port,
        [
          event_sink: self(),
          parent_call_id: "parent-1",
          runtime_source: "runtime",
          external_ids: %{"session_id" => "session-1"},
          journal_path: "/tmp/events.jsonl",
          codec: TestCodec,
          stale_cleanup_timeout_ms: :infinity
        ],
        123
      )

    assert %Stdio{} = state
    assert state.port == :port
    assert state.event_sink == self()
    assert state.parent_call_id == "parent-1"
    assert state.runtime_source == "runtime"
    assert state.external_ids == %{"session_id" => "session-1"}
    assert state.journal_path == "/tmp/events.jsonl"
    assert state.codec == TestCodec
    assert state.cleanup_timeout_ms == :infinity
    assert state.cleanup_timer_ref == nil
    assert state.last_activity_monotonic_ms == 123
    assert state.event_seq == 0
    assert state.request_seq == 0
    assert state.pending == %{}
  end

  test "derives defaults and schedules finite cleanup timer" do
    state = State.build(:port, [stale_cleanup_timeout_ms: 1_000], 456)

    assert state.event_sink == self()
    assert String.starts_with?(state.parent_call_id, "parent-")
    assert state.runtime_source == "synthetic"
    assert state.external_ids == %{}
    assert state.journal_path == nil
    assert state.codec == Ourocode.Json
    assert state.cleanup_timeout_ms == 1_000
    assert is_reference(state.cleanup_timer_ref)
    assert state.last_activity_monotonic_ms == 456

    Process.cancel_timer(state.cleanup_timer_ref)
  end
end
