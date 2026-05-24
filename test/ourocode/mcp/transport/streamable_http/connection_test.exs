defmodule Ourocode.MCP.Transport.StreamableHTTP.ConnectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.StreamableHTTP.Connection

  test "stream_request_data builds POST request with JSON body and custom headers" do
    request = %{"jsonrpc" => "2.0", "id" => "req-1", "method" => "tools/list", "params" => %{}}

    data =
      "http://example.test:4080/mcp?session=abc"
      |> URI.parse()
      |> Connection.stream_request_data(request, headers: [{"authorization", "Bearer test"}])
      |> IO.iodata_to_binary()

    assert data =~ "POST /mcp?session=abc HTTP/1.1\r\n"
    assert data =~ "host: example.test:4080\r\n"
    assert data =~ "accept: application/json, text/event-stream\r\n"
    assert data =~ "content-type: application/json\r\n"
    assert data =~ "connection: close\r\n"
    assert data =~ "authorization: Bearer test\r\n"
    assert data =~ "\r\n\r\n"
    assert data =~ ~s("method":"tools/list")
  end
end
