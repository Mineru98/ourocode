defmodule Ourocode.MCP.Transport.Stdio.StreamProcessorTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Stdio
  alias Ourocode.MCP.Transport.Stdio.PendingRequest
  alias Ourocode.MCP.Transport.Stdio.StreamProcessor

  test "ignores non-protocol helper output" do
    state = base_state()

    assert StreamProcessor.handle_line(state, "helper booted") == state
    refute_receive {:ourocode_event, _event}
  end

  test "emits decode failures for malformed JSON-looking lines" do
    state = base_state()

    next_state = StreamProcessor.handle_line(state, ~s({"jsonrpc":))

    assert next_state.event_seq == 1

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_decode_failed,
                      error: {:malformed_stdout_line, _reason},
                      raw_event: %{
                        line: ~s({"jsonrpc":),
                        stream_direction: :inbound,
                        raw_payload_ref: "sha256:" <> _
                      }
                    }}
  end

  test "normalizes request and notification protocol messages" do
    state = base_state(%{external_ids: %{"session_id" => "session-1"}})

    line =
      ~s({"jsonrpc":"2.0","method":"notifications/progress","params":{"childID":"child-1","seq":1}})

    next_state = StreamProcessor.handle_line(state, line)

    assert next_state.event_seq == 1

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      external_ids: %{"session_id" => "session-1", childID: "child-1"},
                      notification: %{
                        "method" => "notifications/progress",
                        "params" => %{"childID" => "child-1", "seq" => 1}
                      },
                      raw_event: %{stream_direction: :inbound}
                    }}
  end

  test "completes matching pending responses and preserves request metadata" do
    timer = Process.send_after(self(), :unused_timer, 10_000)
    ref = make_ref()

    pending =
      PendingRequest.new(
        {self(), ref},
        "tools/call",
        %{"name" => "demo"},
        %{"session_id" => "session-1"},
        timer,
        123
      )

    state = base_state(%{pending: %{"request-1" => pending}})
    line = ~s({"jsonrpc":"2.0","id":"request-1","result":{"ok":true,"childID":"child-1"}})

    next_state = StreamProcessor.handle_line(state, line)

    assert next_state.pending == %{}
    assert next_state.event_seq == 1
    assert_receive {^ref, {:ok, %{"childID" => "child-1", "ok" => true}}}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      request_id: "request-1",
                      method: "tools/call",
                      params: %{"name" => "demo"},
                      external_ids: %{"session_id" => "session-1", childID: "child-1"},
                      result: %{"childID" => "child-1", "ok" => true},
                      raw_event: %{stream_direction: :inbound}
                    }}

    refute_receive :unused_timer, 20
  end

  test "emits unmatched results when no pending request exists" do
    state = base_state()
    line = ~s({"jsonrpc":"2.0","id":"request-404","result":{"ok":true}})

    next_state = StreamProcessor.handle_line(state, line)

    assert next_state.pending == %{}
    assert next_state.event_seq == 1

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_unmatched_result,
                      request_id: "request-404",
                      result: %{
                        "jsonrpc" => "2.0",
                        "id" => "request-404",
                        "result" => %{"ok" => true}
                      },
                      raw_event: %{stream_direction: :inbound}
                    }}
  end

  defp base_state(attrs \\ %{}) do
    struct!(
      Stdio,
      Map.merge(
        %{
          port: :port,
          event_sink: self(),
          parent_call_id: "parent-1",
          runtime_source: "synthetic",
          external_ids: %{},
          codec: Ourocode.Json,
          event_seq: 0,
          request_seq: 0,
          pending: %{}
        },
        attrs
      )
    )
  end
end
