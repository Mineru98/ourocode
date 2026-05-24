defmodule Ourocode.MCP.Transport.Stdio.OutboundRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Stdio.OutboundRequest

  test "build creates request metadata and lifecycle attributes" do
    state = %{
      request_seq: 4,
      parent_call_id: "parent-1",
      runtime_source: "ouroboros",
      external_ids: %{"session_id" => "session-1"}
    }

    outbound =
      OutboundRequest.build(
        state,
        "tools/call",
        %{"name" => "synthetic", "session_id" => "session-2"},
        [timeout: 123],
        456
      )

    assert outbound.request == %{
             "jsonrpc" => "2.0",
             "id" => "5",
             "method" => "tools/call",
             "params" => %{"name" => "synthetic", "session_id" => "session-2"}
           }

    assert outbound.request_id == "5"
    assert outbound.timeout == 123
    assert outbound.started_at_ms == 456
    assert outbound.external_ids["session_id"] == "session-1"
    assert Map.take(outbound.raw_event, ["jsonrpc", "id", "method", "params"]) == outbound.request
    assert outbound.raw_event.stream_direction == :outbound

    assert OutboundRequest.started_attrs(outbound) == %{
             external_ids: outbound.external_ids,
             request_id: "5",
             method: "tools/call",
             params: %{"name" => "synthetic", "session_id" => "session-2"},
             raw_event: outbound.raw_event
           }
  end

  test "write_failed_attrs keeps identity and raw event without request method payload" do
    outbound =
      OutboundRequest.build(
        %{
          request_seq: 0,
          parent_call_id: "parent-1",
          runtime_source: "ouroboros",
          external_ids: %{}
        },
        "tools/call",
        %{"name" => "synthetic"},
        [timeout: 100],
        1
      )

    attrs = OutboundRequest.write_failed_attrs(outbound, :closed)

    assert attrs.external_ids == outbound.external_ids
    assert attrs.request_id == "1"
    assert attrs.raw_event == outbound.raw_event
    assert attrs.error == :closed
    refute Map.has_key?(attrs, :method)
    refute Map.has_key?(attrs, :params)
  end
end
