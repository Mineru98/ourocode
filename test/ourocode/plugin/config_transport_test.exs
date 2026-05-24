defmodule Ourocode.Plugin.ConfigTransportTest do
  use ExUnit.Case, async: true

  alias Ourocode.Plugin.ConfigTransport

  test "parses supported transport declarations in order" do
    transports = [
      %{"type" => "stdio", "command" => "bin/server"},
      %{"type" => "sse", "url" => "http://localhost/sse"},
      %{"type" => "streamable_http", "url" => "http://localhost/mcp"}
    ]

    assert ConfigTransport.parse(%{"transports" => transports}, 0) == {:ok, transports}
    assert ConfigTransport.parse(%{}, 0) == {:ok, []}
  end

  test "rejects unsupported transport type and missing required fields" do
    for unsupported_transport <- ["websocket", "http", "streamable-http", "tcp"] do
      assert ConfigTransport.parse(%{"transports" => [%{"type" => unsupported_transport}]}, 0) ==
               {:error,
                {:invalid_plugin_config_schema,
                 "plugins[0].transports[0].type is unsupported: #{unsupported_transport}; supported MCP transports are sse, stdio, streamable_http"}}
    end

    assert ConfigTransport.parse(%{"transports" => [%{"type" => "stdio"}]}, 1) ==
             {:error,
              {:invalid_plugin_config_schema,
               "plugins[1].transports[0].command must be a non-empty string"}}
  end
end
