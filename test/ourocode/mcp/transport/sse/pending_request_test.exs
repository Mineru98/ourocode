defmodule Ourocode.MCP.Transport.SSE.PendingRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.SSE.PendingRequest

  test "builds pending request and tracks request sequence" do
    from = {self(), make_ref()}
    timer = make_ref()

    pending = PendingRequest.new(from, "tools/call", %{"name" => "synthetic"}, timer)

    assert pending == %{
             from: from,
             method: "tools/call",
             params: %{"name" => "synthetic"},
             timer: timer
           }

    assert PendingRequest.increment_request_seq(%{request_seq: 2}) == %{request_seq: 3}
  end

  test "puts pops and clears pending request state" do
    pending = %{method: "tools/call", params: %{}, timer: make_ref()}
    state = %{pending: %{}}

    state = PendingRequest.put(state, "1", pending)
    assert state.pending == %{"1" => pending}

    assert {^pending, %{pending: %{}}} = PendingRequest.pop(state, "1")
    assert {nil, ^state} = PendingRequest.pop(state, "missing")
    assert PendingRequest.clear(state) == %{pending: %{}}
  end

  test "builds completion context attrs from optional pending request" do
    assert PendingRequest.context_attrs(nil) == %{method: nil, params: nil}

    assert PendingRequest.context_attrs(%{method: "tools/call", params: %{"name" => "x"}}) ==
             %{method: "tools/call", params: %{"name" => "x"}}
  end

  test "builds parent call failure event attrs" do
    pending = %{method: "tools/call", params: %{"name" => "x"}}

    assert PendingRequest.failed_event_attrs("1", pending, :transport_closed) == %{
             request_id: "1",
             method: "tools/call",
             params: %{"name" => "x"},
             error: :transport_closed
           }
  end
end
