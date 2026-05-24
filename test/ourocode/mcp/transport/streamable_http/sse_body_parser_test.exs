defmodule Ourocode.MCP.Transport.StreamableHTTP.SSEBodyParserTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.StreamableHTTP.SSEBodyParser

  test "parse decodes SSE data frames and preserves id and event metadata" do
    body = """
    : keepalive
    id: evt-1
    event: progress
    data: {"jsonrpc":"2.0","method":"notifications/progress"}

    data: {"jsonrpc":"2.0","id":"call-1","result":{"ok":true}}

    """

    assert {:ok, [first, second]} = SSEBodyParser.parse(body)

    assert first["id"] == "evt-1"
    assert first["event"] == "progress"
    assert first["data"] == %{"jsonrpc" => "2.0", "method" => "notifications/progress"}

    assert second["id"] == nil
    assert second["event"] == "message"
    assert second["data"] == %{"jsonrpc" => "2.0", "id" => "call-1", "result" => %{"ok" => true}}
  end

  test "parse joins multiline data before decoding JSON" do
    body = """
    data: {"jsonrpc":"2.0",
    data: "method":"notifications/progress"}

    """

    assert {:ok, [event]} = SSEBodyParser.parse(body)
    assert event["data"] == %{"jsonrpc" => "2.0", "method" => "notifications/progress"}
  end

  test "parse ignores metadata-only frames and returns JSON decode errors" do
    assert {:ok, []} = SSEBodyParser.parse("retry: 1000\n\n")

    assert {:error, _reason} = SSEBodyParser.parse("data: {invalid\n\n")
  end
end
