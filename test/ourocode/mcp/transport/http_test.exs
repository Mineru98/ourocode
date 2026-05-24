defmodule Ourocode.MCP.Transport.HttpTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.Http

  test "parse_http_url accepts only http URLs with a host" do
    assert {:ok, %URI{scheme: "http", host: "localhost", port: 4000}} =
             Http.parse_http_url("http://localhost:4000/mcp")

    assert Http.parse_http_url("https://localhost/mcp") ==
             {:error, {:unsupported_scheme, "https"}}

    assert Http.parse_http_url("http:/missing-host") ==
             {:error, {:invalid_url, "http:/missing-host"}}
  end

  test "parse_optional_http_url! raises with the supplied label" do
    assert Http.parse_optional_http_url!(nil, "dispatch_url") == nil

    assert_raise ArgumentError, ~r/invalid dispatch_url/, fn ->
      Http.parse_optional_http_url!("ftp://example.test", "dispatch_url")
    end
  end

  test "host_header and request_target preserve ports, paths, and queries" do
    assert {:ok, uri} = Http.parse_http_url("http://example.test:8080/mcp?session=abc")

    assert Http.host_header(uri) == "example.test:8080"
    assert Http.request_target(uri) == "/mcp?session=abc"

    assert {:ok, root_uri} = Http.parse_http_url("http://example.test")
    assert Http.host_header(root_uri) == "example.test"
    assert Http.request_target(root_uri) == "/"
  end

  test "parse_response_headers extracts status and lower-case header keys" do
    assert Http.parse_response_headers(
             "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nX-Test: yes\r\n"
           ) ==
             {:ok, 200, [{"content-type", "text/event-stream"}, {"x-test", "yes"}]}

    assert Http.parse_response_headers("not-http\r\n") ==
             {:error, {:invalid_response_headers, "not-http\r\n"}}
  end

  test "event_stream? handles mixed key and value types" do
    assert Http.event_stream?([{~c"content-type", ~c"text/event-stream; charset=utf-8"}])
    assert Http.event_stream?([{"Content-Type", "TEXT/EVENT-STREAM"}])
    refute Http.event_stream?([{"content-type", "application/json"}])
  end

  test "header conversion helpers preserve values as strings and charlists" do
    assert Http.normalize_headers([{~c"Content-Type", ~c"application/json"}]) == [
             {"Content-Type", "application/json"}
           ]

    assert Http.charlist_headers([{"x-test", :ok}]) == [{~c"x-test", ~c"ok"}]
  end
end
