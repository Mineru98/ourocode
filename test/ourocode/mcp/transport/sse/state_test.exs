defmodule Ourocode.MCP.Transport.SSE.StateTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.SSE
  alias Ourocode.MCP.Transport.SSE.State

  test "builds initial transport state with explicit options" do
    uri = URI.parse("http://localhost:4001/events?session=query-session")

    state =
      State.build(:socket, uri,
        event_sink: self(),
        parent_call_id: "parent-1",
        runtime_source: "runtime",
        external_ids: %{"session_id" => "external-session"},
        dispatch_url: "http://localhost:4001/messages",
        headers: [{"authorization", "Bearer token"}],
        journal_path: "/tmp/events.jsonl",
        raw_payload_store_dir: "/tmp/raw",
        connection_identifier: "connection-1",
        session_identifier: "session-1",
        event_seq: 7
      )

    assert %SSE{} = state
    assert state.socket == :socket
    assert state.event_sink == self()
    assert state.parent_call_id == "parent-1"
    assert state.runtime_source == "runtime"
    assert state.external_ids == %{"session_id" => "external-session"}
    assert state.dispatch_uri == URI.parse("http://localhost:4001/messages")
    assert state.endpoint_url == "http://localhost:4001/events?session=query-session"
    assert state.connection_identifier == "connection-1"
    assert state.session_identifier == "session-1"
    assert state.request_headers == [{"authorization", "Bearer token"}]
    assert state.journal_path == "/tmp/events.jsonl"
    assert state.raw_payload_store_dir == "/tmp/raw"
    assert state.event_seq == 7
  end

  test "derives defaults from URL, external ids, and journal path" do
    uri = URI.parse("http://localhost:4001/events?session=query-session")

    state =
      State.build(:socket, uri,
        external_ids: %{"session_id" => "external-session"},
        journal_path: "/tmp/events.jsonl"
      )

    assert state.event_sink == self()
    assert String.starts_with?(state.parent_call_id, "parent-")
    assert state.runtime_source == "synthetic"
    assert state.dispatch_uri == nil
    assert String.starts_with?(state.connection_identifier, "sse-connection-")
    assert state.session_identifier == "external-session"
    assert state.request_headers == []
    assert state.raw_payload_store_dir == "/tmp/events.jsonl.raw_sse_payloads"
    assert state.event_seq == 0
  end
end
