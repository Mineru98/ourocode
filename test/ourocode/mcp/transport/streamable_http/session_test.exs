defmodule Ourocode.MCP.Transport.StreamableHTTP.SessionTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Transport.StreamableHTTP.Session

  test "has_header? detects existing headers case-insensitively" do
    options = [headers: [{"MCP-Session-ID", "session-1"}]]

    assert Session.has_header?(options, "mcp-session-id")
    refute Session.has_header?(options, "mcp-protocol-version")
  end

  test "header_value reads charlist and string headers case-insensitively" do
    headers = [{~c"MCP-Session-ID", ~c"session-1"}, {"content-type", "application/json"}]

    assert Session.header_value(headers, "mcp-session-id") == "session-1"
    assert Session.header_value(headers, "Content-Type") == "application/json"
    assert Session.header_value(headers, "missing") == nil
  end

  test "put_session_headers prepends MCP session headers without dropping existing headers" do
    options =
      [headers: [{"x-existing", "1"}]]
      |> Session.put_session_headers("session-1", "2025-06-18")

    assert Keyword.fetch!(options, :headers) == [
             {"mcp-session-id", "session-1"},
             {"mcp-protocol-version", "2025-06-18"},
             {"x-existing", "1"}
           ]
  end

  test "ensure skips handshake when session support is disabled or header already exists" do
    assert Session.ensure("http://127.0.0.1:1/mcp", [], "2025-06-18", 1) == {:ok, []}

    options = [mcp_session: true, headers: [{"mcp-session-id", "session-1"}]]

    assert Session.ensure("http://127.0.0.1:1/mcp", options, "2025-06-18", 1) ==
             {:ok, options}
  end
end
