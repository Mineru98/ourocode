defmodule Ourocode.MCP.Transport.SSE.DispatchTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.SSE.Dispatch

  test "request rejects missing dispatch URL before HTTP work" do
    assert Dispatch.request(%{dispatch_uri: nil, status: 200}, %{}, 100) ==
             {:error, :missing_dispatch_url}
  end

  test "request rejects calls before SSE connection is established" do
    assert Dispatch.request(
             %{dispatch_uri: URI.parse("http://127.0.0.1/messages"), status: nil},
             %{},
             100
           ) ==
             {:error, :sse_not_connected}
  end

  test "decode_response parses success bodies and empty success responses" do
    assert Dispatch.decode_response(202, "") == {:ok, nil}
    assert Dispatch.decode_response(200, ~s({"accepted":true})) == {:ok, %{"accepted" => true}}
  end

  test "decode_response returns structured HTTP errors" do
    assert Dispatch.decode_response(500, "boom") == {:error, {:http_error, 500, "boom"}}
  end
end
