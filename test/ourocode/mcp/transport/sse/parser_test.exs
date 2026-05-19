defmodule Ourocode.MCP.Transport.SSE.ParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.SSE.Parser

  test "preserves event and id fields from a complete frame" do
    payload =
      %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    frame = [
      "event: child-token\n",
      "id: sse-42\n",
      "data: ",
      payload,
      "\n\n"
    ]

    assert {:ok,
            [
              %{
                "event" => "child-token",
                "id" => "sse-42",
                "data" => %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
              }
            ], ""} = Parser.parse_complete_frames(IO.iodata_to_binary(frame))
  end

  test "joins multiple data lines in a complete frame using SSE newline rules" do
    frame = [
      "event: child-token\n",
      "data: {\"jsonrpc\":\"2.0\",\n",
      "data\n",
      "data: \"method\":\"notifications/progress\",\n",
      "data: \"params\":{\"token\":\"hello\"}}\n\n"
    ]

    assert {:ok,
            [
              %{
                "event" => "child-token",
                "id" => nil,
                "data" => %{
                  "jsonrpc" => "2.0",
                  "method" => "notifications/progress",
                  "params" => %{"token" => "hello"}
                }
              }
            ], ""} = Parser.parse_complete_frames(IO.iodata_to_binary(frame))
  end

  test "emits one parsed frame per complete blank-line-delimited SSE frame" do
    first =
      %{"jsonrpc" => "2.0", "method" => "notifications/one"}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    second =
      %{"jsonrpc" => "2.0", "method" => "notifications/two"}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    incomplete =
      %{"jsonrpc" => "2.0", "method" => "notifications/three"}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    buffer = [
      "event: progress\r\n",
      "id: evt-1\r\n",
      "data: ",
      first,
      "\r\n\r\n",
      ": keepalive\n\n",
      "data: ",
      second,
      "\n\n",
      "data: ",
      incomplete
    ]

    assert {:ok,
            [
              %{
                "event" => "progress",
                "id" => "evt-1",
                "data" => %{"jsonrpc" => "2.0", "method" => "notifications/one"}
              },
              %{
                "event" => "message",
                "id" => nil,
                "data" => %{"jsonrpc" => "2.0", "method" => "notifications/two"}
              }
            ], rest} = Parser.parse_complete_frames(IO.iodata_to_binary(buffer))

    assert rest == "data: " <> incomplete
  end

  test "ignores comment-only frames without dropping following data frames" do
    payload =
      %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    buffer = [
      ": keepalive\n",
      ": server is still working\n\n",
      "event: child-token\n",
      "data: ",
      payload,
      "\n\n"
    ]

    assert {:ok,
            [
              %{
                "event" => "child-token",
                "id" => nil,
                "data" => %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
              }
            ], ""} = Parser.parse_complete_frames(IO.iodata_to_binary(buffer))
  end

  test "preserves incomplete frame bytes across chunk boundaries until the delimiter completes" do
    payload =
      %{"jsonrpc" => "2.0", "method" => "notifications/progress", "params" => %{"seq" => 7}}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    chunks = [
      "event: child-token\r\nid: split-",
      "frame\r\ndata: ",
      payload,
      "\r\n",
      "\r",
      "\n"
    ]

    {events, rest} =
      Enum.reduce(chunks, {[], ""}, fn chunk, {events, rest} ->
        assert {:ok, parsed_events, next_rest} = Parser.parse_complete_frames(rest <> chunk)

        if chunk != List.last(chunks) do
          assert parsed_events == []
          assert next_rest == rest <> chunk
        end

        {events ++ parsed_events, next_rest}
      end)

    assert events == [
             %{
               "event" => "child-token",
               "id" => "split-frame",
               "data" => %{
                 "jsonrpc" => "2.0",
                 "method" => "notifications/progress",
                 "params" => %{"seq" => 7}
               }
             }
           ]

    assert rest == ""
  end

  test "parses retry fields as reconnection delay metadata only after a complete frame" do
    payload =
      %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
      |> Json.encode!()
      |> IO.iodata_to_binary()

    partial = [
      "retry: 2500\n",
      "event: progress\n",
      "data: ",
      payload,
      "\n"
    ]

    assert {:ok, [], rest} = Parser.parse_complete_frames(IO.iodata_to_binary(partial))
    assert rest == IO.iodata_to_binary(partial)

    assert {:ok,
            [
              %{
                "event" => "progress",
                "id" => nil,
                "retry" => 2500,
                "metadata" => %{"reconnection_delay_ms" => 2500},
                "data" => %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
              }
            ], ""} = Parser.parse_complete_frames(rest <> "\n")
  end

  test "parses retry-only frames as reconnection delay metadata" do
    assert {:ok,
            [
              %{
                "event" => "message",
                "id" => nil,
                "retry" => 5000,
                "metadata" => %{"reconnection_delay_ms" => 5000}
              }
            ], ""} = Parser.parse_complete_frames("retry: 5000\n\n")
  end

  test "ignores malformed retry fields instead of emitting retry metadata" do
    assert {:ok, [], ""} = Parser.parse_complete_frames("retry: later\n\n")
  end

  test "returns malformed data frame decode errors for transport failure handling" do
    assert {:error, {:expected_object_key, "malformed json"}} =
             Parser.parse_complete_frames("event: child-token\ndata: {malformed json\n\n")
  end
end
