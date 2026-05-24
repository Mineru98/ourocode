defmodule Ourocode.MCP.Transport.SSE.ParentCallTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.SSE.ParentCall

  test "request_id uses explicit request ids before state sequence" do
    assert ParentCall.request_id(%{request_seq: 41}, request_id: "custom") == "custom"
    assert ParentCall.request_id(%{request_seq: 41}, []) == "42"
  end

  test "request builds a JSON-RPC parent call payload" do
    assert ParentCall.request("call-1", "tools/call", %{name: "ooo.run"}) == %{
             "jsonrpc" => "2.0",
             "id" => "call-1",
             "method" => "tools/call",
             "params" => %{name: "ooo.run"}
           }
  end

  test "handle_call emits write failure when dispatch endpoint is missing" do
    from = {self(), make_ref()}
    state = state(dispatch_uri: nil, event_sink: self())

    assert {:reply, {:error, :missing_dispatch_url}, next_state} =
             ParentCall.handle_call(
               state,
               from,
               "tools/call",
               %{name: "ooo.run"},
               [request_id: "call-1"],
               5_000
             )

    assert next_state.event_seq == 1

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_write_failed,
                      request_id: "call-1",
                      method: "tools/call",
                      params: %{name: "ooo.run"},
                      error: :missing_dispatch_url,
                      event_seq: 1,
                      raw_event: %{
                        "jsonrpc" => "2.0",
                        "id" => "call-1",
                        "method" => "tools/call",
                        "params" => %{name: "ooo.run"}
                      }
                    }}
  end

  defp state(overrides) do
    Map.merge(
      %{
        dispatch_uri: URI.parse("http://127.0.0.1/messages"),
        event_sink: nil,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{},
        event_seq: 0,
        request_seq: 0,
        pending: %{},
        status: 200,
        headers: []
      },
      Map.new(overrides)
    )
  end
end
