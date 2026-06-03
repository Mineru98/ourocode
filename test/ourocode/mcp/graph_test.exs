defmodule Ourocode.MCP.GraphTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.Graph

  test "normalizes tools/list payloads into a server tool graph" do
    event = %{
      runtime_source: "ouroboros",
      transport: :streamable_http,
      payload: %{
        "result" => %{
          "tools" => [
            %{
              "name" => "ouroboros_auto",
              "description" => "Run full-quality ooo auto",
              "inputSchema" => %{"type" => "object"}
            }
          ]
        }
      }
    }

    assert %{
             servers: [
               %{
                 id: "mcp-server:ouroboros",
                 name: "ouroboros",
                 transport: "streamable_http",
                 runtime_source: "ouroboros"
               }
             ],
             tools: [
               %{
                 id: "mcp-server:ouroboros/tool/ouroboros_auto",
                 name: "ouroboros_auto",
                 server_id: "mcp-server:ouroboros",
                 description: "Run full-quality ooo auto",
                 input_schema: %{"type" => "object"}
               }
             ],
             edges: [
               %{
                 from: "mcp-server:ouroboros",
                 to: "mcp-server:ouroboros/tool/ouroboros_auto",
                 kind: :server_tool
               }
             ]
           } = Graph.from_event(event)
  end

  test "renders discovered tools with input schema details" do
    graph =
      Graph.from_event(%{
        runtime_source: "ouroboros",
        payload: %{
          "tools" => [
            %{
              "name" => "ouroboros_auto",
              "description" => "Run auto",
              "inputSchema" => %{
                "type" => "object",
                "required" => ["goal"],
                "properties" => %{
                  "goal" => %{"type" => "string", "description" => "Target outcome"}
                }
              }
            }
          ]
        }
      })

    text = Graph.render_text(graph)

    assert text =~ "MCPGraph: 1 servers, 1 tools"
    assert text =~ "tool ouroboros_auto"
    assert text =~ "schema type=object required=goal"
    assert text =~ "arg goal: string required - Target outcome"
  end

  test "extracts nested capability payloads from JSON-RPC results" do
    tools = [%{"name" => "ouroboros_interview"}]

    assert Graph.tools_from_event(%{payload: %{"result" => %{"tools" => tools}}}) == tools
    assert Graph.tools_from_event(%{result: %{tools: tools}}) == tools
    assert Graph.tools_from_event(%{payload: %{}}) == []
  end
end
