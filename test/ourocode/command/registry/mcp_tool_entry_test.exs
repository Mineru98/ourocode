defmodule Ourocode.Command.Registry.McpToolEntryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.McpToolEntry

  test "build normalizes one MCP tool into a runnable command entry" do
    context = %{
      transport: :streamable_http,
      source_id: "remote-tools",
      discovered_from: "tools/list"
    }

    assert entry =
             McpToolEntry.build(
               %{
                 "name" => "remote.review",
                 "title" => "Remote Review",
                 "description" => "Review through a remote MCP server.",
                 "aliases" => ["rr"],
                 "inputSchema" => %{
                   "required" => ["path"],
                   "properties" => %{
                     "path" => %{"description" => "Path to review"},
                     "limit" => %{"description" => "Maximum issues"}
                   }
                 },
                 "annotations" => %{"userInvocable" => true}
               },
               context
             )

    assert entry.id == "mcp:remote-tools:remote.review"
    assert entry.name == "remote-review"
    assert entry.slash == "/remote-review"
    assert entry.aliases == ["/rr"]

    assert entry.args == [
             %{name: "limit", required?: false, description: "Maximum issues"},
             %{name: "path", required?: true, description: "Path to review"}
           ]

    assert entry.run_spec.kind == :mcp_tool
    assert entry.run_spec.transport == :streamable_http
    assert entry.metadata.invocability.source == :annotation_user_invocable
  end

  test "envelope helpers read nested tool lists and context metadata" do
    envelope = %{
      transport: "streamable-http",
      session_id: "agent-tools",
      discovered_from: "refresh",
      result: %{tools: [%{name: "agent.summarize", input_schema: %{}}]}
    }

    assert McpToolEntry.tool_list(envelope) == [%{name: "agent.summarize", input_schema: %{}}]

    assert McpToolEntry.envelope_context(envelope) == %{
             transport: :streamable_http,
             source_id: "agent-tools",
             discovered_from: "refresh"
           }
  end

  test "tool_entry? and user_invocable? keep internal tools out of command surface" do
    assert McpToolEntry.tool_entry?(%{name: "fs.search", input_schema: %{}})
    assert McpToolEntry.tool_entry?(%{name: "fs.search"})
    refute McpToolEntry.tool_entry?(%{kind: "resource"})

    assert McpToolEntry.user_invocable?(%{"name" => "visible"})
    refute McpToolEntry.user_invocable?(%{"annotations" => %{"userInvocable" => false}})
    refute McpToolEntry.user_invocable?(%{"user_invocable" => "false"})
  end

  test "build ignores unnamed tools" do
    assert McpToolEntry.build(%{"name" => "  "}, %{transport: :stdio, source_id: "mcp"}) == nil
  end
end
