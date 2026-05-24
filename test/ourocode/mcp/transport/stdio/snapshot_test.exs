defmodule Ourocode.MCP.Transport.Stdio.SnapshotTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Stdio.Snapshot

  test "build projects transport metadata without exposing pending internals" do
    state = %{
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      external_ids: %{"session_id" => "session-1"},
      event_seq: 7,
      request_seq: 3,
      pending: %{"1" => :pending, "2" => :pending},
      port: :not_a_port,
      cleanup_timeout_ms: 500,
      last_activity_monotonic_ms: 123
    }

    assert Snapshot.build(state) == %{
             transport: :stdio,
             parent_call_id: "parent-1",
             runtime_source: "ouroboros",
             external_ids: %{"session_id" => "session-1"},
             event_seq: 7,
             request_seq: 3,
             pending_request_count: 2,
             port: :not_a_port,
             port_open?: false,
             cleanup_timeout_ms: 500,
             last_activity_monotonic_ms: 123
           }
  end
end
