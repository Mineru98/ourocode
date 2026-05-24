defmodule Ourocode.MCP.Transport.StreamableHTTP.SSEStreamTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.StreamableHTTP.SSEStream

  test "parse_complete_frames_with_raw returns parsed events with their original frames and rest" do
    frame_1 = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"progress\"}\n\n"
    frame_2 = "data: {\"id\":\"call-1\",\"result\":{\"ok\":true}}\n\n"
    raw_frame_1 = String.trim_trailing(frame_1)
    raw_frame_2 = String.trim_trailing(frame_2)
    rest = "data: {\"partial\": true"

    assert {:ok, [{event_1, ^raw_frame_1}, {event_2, ^raw_frame_2}], ^rest} =
             SSEStream.parse_complete_frames_with_raw(frame_1 <> frame_2 <> rest)

    assert event_1 == %{
             "event" => "message",
             "id" => nil,
             "data" => %{"jsonrpc" => "2.0", "method" => "progress"}
           }

    assert event_2 == %{
             "event" => "message",
             "id" => nil,
             "data" => %{"id" => "call-1", "result" => %{"ok" => true}}
           }
  end

  test "parse_complete_frames_with_raw surfaces invalid frame errors" do
    assert {:error, _reason} =
             SSEStream.parse_complete_frames_with_raw("data: {not-json}\n\n")
  end

  test "raw_response_event_payload prefers data or metadata and keeps SSE identifiers" do
    assert SSEStream.raw_response_event_payload(%{
             "id" => "event-1",
             "event" => "message",
             "data" => %{"childID" => "child-1"}
           }) == %{
             "childID" => "child-1",
             sse_event_id: "event-1",
             sse_event_type: "message"
           }

    assert SSEStream.raw_response_event_payload(%{
             "id" => "event-2",
             "metadata" => %{"token" => "abc"}
           }) == %{
             "token" => "abc",
             sse_event_id: "event-2",
             sse_event_type: nil
           }
  end
end
