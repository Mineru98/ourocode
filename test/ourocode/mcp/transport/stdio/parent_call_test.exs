defmodule Ourocode.MCP.Transport.Stdio.ParentCallTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.MCP.Transport.Stdio.ParentCall

  test "handle_call writes request, registers pending call, and emits started event" do
    from = {self(), make_ref()}
    test_pid = self()

    write_fun = fn _state, request ->
      send(test_pid, {:written_request, request})
      :ok
    end

    assert {:noreply, state} =
             ParentCall.handle_call(
               state(event_sink: self(), request_seq: 4),
               from,
               "tools/call",
               %{"name" => "synthetic"},
               [timeout: 500],
               5_000,
               123,
               write_fun
             )

    assert_receive {:written_request,
                    %{
                      "jsonrpc" => "2.0",
                      "id" => "5",
                      "method" => "tools/call",
                      "params" => %{"name" => "synthetic"}
                    }}

    assert state.request_seq == 5

    assert %{from: ^from, method: "tools/call", params: %{"name" => "synthetic"}} =
             state.pending["5"]

    assert is_reference(state.pending["5"].timer)
    Process.cancel_timer(state.pending["5"].timer)

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_started,
                      request_id: "5",
                      method: "tools/call",
                      params: %{"name" => "synthetic"},
                      event_seq: 1
                    }}
  end

  test "handle_call emits write failure without registering pending state" do
    from = {self(), make_ref()}

    assert {:reply, {:error, :closed}, state} =
             ParentCall.handle_call(
               state(event_sink: self()),
               from,
               "tools/call",
               %{"name" => "synthetic"},
               [timeout: 500],
               5_000,
               123,
               fn _state, _request -> {:error, :closed} end
             )

    assert state.pending == %{}
    assert state.request_seq == 0

    assert_receive {:ourocode_event,
                    %LifecycleEvent{
                      type: :parent_call_write_failed,
                      request_id: "1",
                      error: :closed,
                      event_seq: 1
                    }}
  end

  defp state(overrides) do
    Map.merge(
      %{
        port: nil,
        event_sink: nil,
        parent_call_id: "parent-1",
        runtime_source: "synthetic",
        external_ids: %{},
        journal_path: nil,
        codec: nil,
        cleanup_timeout_ms: :infinity,
        cleanup_timer_ref: nil,
        last_activity_monotonic_ms: nil,
        event_seq: 0,
        request_seq: 0,
        pending: %{}
      },
      Map.new(overrides)
    )
  end
end
