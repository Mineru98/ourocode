defmodule Ourocode.MCP.Transport.StreamableHTTP.ParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.StreamableHTTP.Parser

  test "preserves event ordering and frame boundaries across partial chunks" do
    first_payload =
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-http-parser-1", "seq" => 1, "token" => "alpha"}
      }
      |> Json.encode!()
      |> IO.iodata_to_binary()

    second_payload =
      %{
        "jsonrpc" => "2.0",
        "method" => "notifications/progress",
        "params" => %{"childID" => "child-http-parser-1", "seq" => 2, "token" => "beta"}
      }
      |> Json.encode!()
      |> IO.iodata_to_binary()

    final_payload =
      %{
        "jsonrpc" => "2.0",
        "id" => "call-http-parser-1",
        "result" => %{"childID" => "child-http-parser-1", "seq" => 3, "ok" => true}
      }
      |> Json.encode!()
      |> IO.iodata_to_binary()

    chunks = [
      "event: message\r\nid: first\r\ndata: " <> binary_part(first_payload, 0, 24),
      binary_part(first_payload, 24, byte_size(first_payload) - 24) <> "\r",
      "\n",
      "\r",
      "\nevent: message\nid: second\ndata: " <>
        binary_part(second_payload, 0, byte_size(second_payload) - 9),
      binary_part(second_payload, byte_size(second_payload) - 9, 9) <>
        "\n\n" <> "event: message\ndata: " <> binary_part(final_payload, 0, 18),
      binary_part(final_payload, 18, byte_size(final_payload) - 18) <> "\n",
      "\n"
    ]

    expected_emitted_counts = [0, 0, 0, 0, 1, 1, 0, 1]

    {events, rest} =
      chunks
      |> Enum.zip(expected_emitted_counts)
      |> Enum.reduce({[], ""}, fn {chunk, expected_count}, {events, rest} ->
        assert {:ok, parsed_events, next_rest} = Parser.parse_complete_events(rest <> chunk)
        assert length(parsed_events) == expected_count
        {events ++ parsed_events, next_rest}
      end)

    assert rest == ""
    assert Enum.map(events, & &1["id"]) == ["first", "second", nil]

    assert Enum.map(events, & &1["data"]) == [
             %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "childID" => "child-http-parser-1",
                 "seq" => 1,
                 "token" => "alpha"
               }
             },
             %{
               "jsonrpc" => "2.0",
               "method" => "notifications/progress",
               "params" => %{
                 "childID" => "child-http-parser-1",
                 "seq" => 2,
                 "token" => "beta"
               }
             },
             %{
               "jsonrpc" => "2.0",
               "id" => "call-http-parser-1",
               "result" => %{"childID" => "child-http-parser-1", "seq" => 3, "ok" => true}
             }
           ]
  end
end
