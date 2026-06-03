defmodule Ourocode.Runtime.McpCapabilitiesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.McpCapabilities

  test "converts named MCP tools to dynamic skill definitions" do
    assert McpCapabilities.capability_skill(%{
             "name" => "ouroboros_seed",
             "description" => "Generate a Seed",
             "inputSchema" => %{
               "required" => ["goal"],
               "properties" => %{
                 "goal" => %{"type" => "string", "description" => "Seed goal"}
               }
             }
           }) == %{
             "name" => "ouroboros_seed",
             "id" => "ouroboros_seed",
             "description" => "Generate a Seed",
             "mcp_tool" => "ouroboros_seed",
             "input_schema" => %{
               "required" => ["goal"],
               "properties" => %{
                 "goal" => %{"type" => "string", "description" => "Seed goal"}
               }
             },
             "args" => [
               %{"name" => "goal", "required" => true, "description" => "Seed goal"}
             ],
             "source_id" => "ouroboros",
             "discovered_from" => "ouroboros-mcp"
           }

    assert McpCapabilities.capability_skill(%{bogus: "missing name"}) == nil
  end

  test "extracts tools from direct and nested MCP capability payloads" do
    tools = [%{"name" => "ouroboros_interview"}]

    assert McpCapabilities.tools_from_event(%{payload: %{"result" => %{"tools" => tools}}}) ==
             tools

    assert McpCapabilities.tools_from_event(%{payload: %{result: %{tools: tools}}}) == tools
    assert McpCapabilities.tools_from_event(%{result: %{tools: tools}}) == tools
    assert McpCapabilities.tools_from_event(%{payload: %{}}) == []
  end
end
