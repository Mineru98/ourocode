defmodule Ourocode.MCP.Transport.SSE.ConnectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.SSE.Connection

  test "request builds an SSE GET request with default and custom headers" do
    request =
      "http://example.test:4080/mcp/sse?token=abc"
      |> URI.parse()
      |> Connection.request([{"authorization", "Bearer test"}])
      |> IO.iodata_to_binary()

    assert request =~ "GET /mcp/sse?token=abc HTTP/1.1\r\n"
    assert request =~ "host: example.test:4080\r\n"
    assert request =~ "accept: text/event-stream\r\n"
    assert request =~ "cache-control: no-cache\r\n"
    assert request =~ "connection: keep-alive\r\n"
    assert request =~ "authorization: Bearer test\r\n"
    assert String.ends_with?(request, "\r\n\r\n")
  end

  test "parse_response_buffer classifies complete, partial, and failed responses" do
    assert Connection.parse_response_buffer("HTTP/1.1 200 OK\r\n") == :partial

    assert {:connected, 200, headers, "event: ping\r\n\r\n"} =
             Connection.parse_response_buffer(
               "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n\r\nevent: ping\r\n\r\n"
             )

    assert {"content-type", "text/event-stream"} in headers

    assert {:http_error, 404, _headers} =
             Connection.parse_response_buffer("HTTP/1.1 404 Not Found\r\n\r\n")

    assert Connection.parse_response_buffer("HTTP nope\r\n\r\n") ==
             {:error, {:invalid_response_headers, "HTTP nope"}}

    assert Connection.parse_response_buffer("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\n\r\n") ==
             {:error, :missing_event_stream_content_type}
  end
end
