defmodule Ourocode.MCP.Transport.Stdio.PendingRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Stdio.PendingRequest

  test "builds and registers pending request state" do
    from = {self(), make_ref()}
    timer = make_ref()

    pending =
      PendingRequest.new(
        from,
        "tools/call",
        %{"name" => "synthetic"},
        %{"session_id" => "session-1"},
        timer,
        123
      )

    assert pending == %{
             from: from,
             method: "tools/call",
             params: %{"name" => "synthetic"},
             external_ids: %{"session_id" => "session-1"},
             timer: timer,
             started_at_ms: 123
           }

    state = %{request_seq: 0, pending: %{}}

    assert %{request_seq: 1, pending: %{"1" => ^pending}} =
             PendingRequest.put(state, "1", pending)
  end

  test "pops pending request while preserving the updated state" do
    pending = %{method: "tools/call"}
    state = %{request_seq: 1, pending: %{"1" => pending, "2" => %{method: "other"}}}

    assert {^pending, %{pending: %{"2" => %{method: "other"}}}} =
             PendingRequest.pop(state, "1")

    assert {nil, %{pending: %{"1" => ^pending, "2" => %{method: "other"}}}} =
             PendingRequest.pop(state, "missing")
  end

  test "classifies decoded JSON-RPC responses" do
    assert PendingRequest.reply_from_decoded(%{"result" => %{"ok" => true}}) ==
             {:ok, %{"ok" => true}}

    assert PendingRequest.reply_from_decoded(%{"error" => %{"code" => -1}}) ==
             {:error, %{"code" => -1}}

    assert PendingRequest.reply_from_decoded(%{"jsonrpc" => "2.0", "id" => "1"}) ==
             {:error, {:invalid_response, %{"jsonrpc" => "2.0", "id" => "1"}}}
  end

  test "builds response attributes from pending request metadata" do
    pending = %{method: "tools/call", params: %{"name" => "synthetic"}}

    assert PendingRequest.response_attrs("1", pending) == %{
             request_id: "1",
             method: "tools/call",
             params: %{"name" => "synthetic"}
           }
  end

  test "clears all pending request state" do
    assert PendingRequest.clear(%{pending: %{"1" => %{}}}) == %{pending: %{}}
  end
end
