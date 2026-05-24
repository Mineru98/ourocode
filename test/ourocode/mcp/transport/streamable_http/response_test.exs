defmodule Ourocode.MCP.Transport.StreamableHTTP.ResponseTest do
  use ExUnit.Case, async: true

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.StreamableHTTP.Response

  test "decode decodes JSON responses" do
    body = Json.encode!(%{"jsonrpc" => "2.0", "id" => "call-1", "result" => %{"ok" => true}})

    assert Response.decode(200, [{"content-type", "application/json"}], IO.iodata_to_binary(body)) ==
             {:ok, %{"jsonrpc" => "2.0", "id" => "call-1", "result" => %{"ok" => true}}}
  end

  test "decode returns http errors for non-success statuses" do
    assert Response.decode(500, [], "boom") == {:error, {:http_error, 500, "boom"}}
  end

  test "decode decodes streamed SSE bodies marked as JSON" do
    body = Json.encode!(%{"jsonrpc" => "2.0", "id" => "call-2", "result" => %{"ok" => true}})

    assert Response.decode(
             200,
             [{"x-ourocode-streamed-sse", "true"}],
             IO.iodata_to_binary(body)
           ) ==
             {:ok, %{"jsonrpc" => "2.0", "id" => "call-2", "result" => %{"ok" => true}}}
  end

  test "from_sse_events picks the latest JSON-RPC response event" do
    events = [
      %{"data" => %{"method" => "notifications/message", "params" => %{"seq" => 1}}},
      %{"data" => %{"jsonrpc" => "2.0", "id" => "call-1", "result" => %{"done" => true}}}
    ]

    assert Response.from_sse_events(events) == %{
             "jsonrpc" => "2.0",
             "id" => "call-1",
             "result" => %{"done" => true}
           }
  end

  test "from_sse_events falls back to events envelope when no response exists" do
    events = [
      %{"data" => %{"method" => "notifications/message", "params" => %{"seq" => 1}}},
      %{"data" => %{"method" => "notifications/message", "params" => %{"seq" => 2}}}
    ]

    assert Response.from_sse_events(events) == %{
             "events" => Enum.map(events, &Map.fetch!(&1, "data"))
           }
  end

  test "content_length and streamed_sse? are case-insensitive" do
    assert Response.content_length([{"Content-Length", "42"}]) == 42
    assert Response.content_length([{"content-length", "invalid"}]) == nil

    assert Response.streamed_sse?([{"X-Ourocode-Streamed-SSE", "TRUE"}])
    refute Response.streamed_sse?([{"X-Ourocode-Streamed-SSE", "false"}])
  end
end
