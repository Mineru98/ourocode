defmodule Ourocode.MCP.Transport.StreamableHTTP.CallContextTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.MCP.Transport.StreamableHTTP.CallContext

  test "builds lifecycle normalizer context from string-keyed requests" do
    context =
      CallContext.normalizer(
        [
          parent_call_id: "parent-1",
          runtime_source: "synthetic",
          external_ids: %{"session_id" => "session-1"}
        ],
        %{
          "id" => 7,
          "method" => "tools/call",
          "params" => %{"name" => "ooo.run"}
        },
        3
      )

    assert %{
             event_seq: 3,
             parent_call_id: "parent-1",
             runtime_source: "synthetic",
             external_ids: %{"session_id" => "session-1"},
             request_id: "7",
             method: "tools/call",
             params: %{"name" => "ooo.run"},
             occurred_at_ms: occurred_at_ms
           } = context

    assert is_integer(occurred_at_ms)
  end

  test "builds lifecycle normalizer context from atom-keyed requests with defaults" do
    context =
      CallContext.normalizer(
        [],
        %{id: :call_atom, method: "tools/list", params: []},
        1
      )

    assert context.parent_call_id == "call_atom"
    assert context.runtime_source == "synthetic"
    assert context.external_ids == %{}
    assert context.request_id == "call_atom"
    assert context.method == "tools/list"
    assert context.params == []
  end

  test "builds parent call result from response metadata" do
    assert %ParentCallResult{} =
             result =
             CallContext.result(
               [
                 parent_call_id: "parent-1",
                 runtime_source: "synthetic",
                 external_ids: %{session_id: "session-1"}
               ],
               200,
               [{"content-type", "application/json"}],
               %{"id" => "call-1", "result" => %{"ok" => true}}
             )

    assert result.parent_call_id == "parent-1"
    assert result.runtime_source == "synthetic"
    assert result.transport == :streamable_http
    assert result.external_ids == %{session_id: "session-1"}
    assert result.status == 200
    assert result.headers == [{"content-type", "application/json"}]
    assert result.response == %{"id" => "call-1", "result" => %{"ok" => true}}
    assert is_integer(result.received_at)
  end

  test "tracks next event sequence and normalizes request ids" do
    assert CallContext.next_event_seq([]) == 1
    assert CallContext.next_event_seq(event_seq: 4) == 5
    assert CallContext.normalize_request_id(nil) == nil
    assert CallContext.normalize_request_id(123) == "123"
  end
end
