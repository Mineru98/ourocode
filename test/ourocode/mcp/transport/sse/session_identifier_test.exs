defmodule Ourocode.MCP.Transport.SSE.SessionIdentifierTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.SSE.SessionIdentifier

  test "prefers explicit external session ids over URL query and request target" do
    uri = URI.parse("http://localhost/mcp/events?session=query-session")

    assert SessionIdentifier.from_uri_and_external_ids(uri, %{"session_id" => "external-session"}) ==
             "external-session"

    assert SessionIdentifier.from_uri_and_external_ids(uri, %{sessionId: "camel-session"}) ==
             "camel-session"
  end

  test "falls back to query session and then request target" do
    assert SessionIdentifier.from_uri_and_external_ids(
             URI.parse("http://localhost/mcp/events?session=query-session"),
             %{}
           ) == "query-session"

    assert SessionIdentifier.from_uri_and_external_ids(
             URI.parse("http://localhost/mcp/events"),
             %{}
           ) ==
             "/mcp/events"
  end

  test "ignores malformed query strings" do
    assert SessionIdentifier.from_uri_and_external_ids(
             URI.parse("http://localhost/mcp/events?%"),
             %{}
           ) ==
             "/mcp/events?%"
  end
end
