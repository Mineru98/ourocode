defmodule Ourocode.MCP.Transport.SSE.StreamProcessorTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.SSE
  alias Ourocode.MCP.Transport.SSE.PendingRequest
  alias Ourocode.MCP.Transport.SSE.StreamProcessor

  test "keeps partial HTTP response bytes buffered" do
    state = base_state(%{response_buffer: "HTTP/1.1 200 OK\r\n"})

    assert StreamProcessor.process_response_chunk(state) == state
  end

  test "connects response and processes complete SSE frames from the remaining bytes" do
    response =
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\n" <>
        "data: {\"method\":\"notifications/progress\",\"params\":{\"progress\":1}}\n\n"

    state = base_state(%{response_buffer: response})

    next_state = StreamProcessor.process_response_chunk(state)

    assert next_state.status == 200
    assert next_state.response_buffer == ""
    assert next_state.sse_buffer == ""
    assert next_state.event_seq == 2

    assert_receive {:ourocode_event, %{type: :transport_connected, event_seq: 1}}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_event,
                      event_seq: 2,
                      notification: %{
                        "method" => "notifications/progress",
                        "params" => %{"progress" => 1}
                      }
                    }}
  end

  test "completes pending parent calls when a matching result arrives" do
    timer = Process.send_after(self(), :unused_timer, 10_000)
    ref = make_ref()

    pending = PendingRequest.new({self(), ref}, "tools/call", %{"name" => "demo"}, timer)

    state =
      base_state(%{
        status: 200,
        headers: [{"content-type", "text/event-stream"}],
        pending: %{"request-1" => pending},
        sse_buffer: "data: {\"id\":\"request-1\",\"result\":{\"ok\":true}}\n\n"
      })

    next_state = StreamProcessor.process_sse_chunk(state)

    assert next_state.pending == %{}
    assert next_state.sse_buffer == ""
    assert next_state.event_seq == 1
    assert_receive {^ref, {:ok, %{"ok" => true}}}

    assert_receive {:ourocode_event,
                    %{
                      type: :parent_call_result,
                      request_id: "request-1",
                      method: "tools/call",
                      params: %{"name" => "demo"},
                      result: %{"ok" => true}
                    }}

    refute_receive :unused_timer, 20
  end

  test "emits decode failures with raw SSE frame metadata" do
    state = base_state(%{sse_buffer: "event: broken\nid: frame-1\ndata: nope\n\n"})

    next_state = StreamProcessor.process_sse_chunk(state)

    assert next_state.sse_buffer == ""
    assert next_state.event_seq == 1

    assert_receive {:ourocode_event,
                    %{
                      type: :transport_decode_failed,
                      raw_event: %{
                        sse_event_id: "frame-1",
                        sse_event_type: "broken",
                        raw_payload_ref: "sha256:" <> _
                      }
                    }}
  end

  defp base_state(attrs) do
    struct!(
      SSE,
      Map.merge(
        %{
          socket: :socket,
          event_sink: self(),
          parent_call_id: "parent-1",
          runtime_source: "synthetic",
          external_ids: %{},
          endpoint_url: "http://localhost:4001/events",
          connection_identifier: "connection-1",
          session_identifier: "session-1",
          event_seq: 0,
          pending: %{},
          response_buffer: "",
          sse_buffer: ""
        },
        attrs
      )
    )
  end
end
