defmodule Ourocode.Command.Registry.McpToolLoaderTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.McpToolLoader

  test "normalizes tools/list envelopes into runnable MCP command entries" do
    assert [entry] =
             McpToolLoader.entries(%{
               transport: "streamable-http",
               server_id: "remote-tools",
               discovered_from: "tools/list",
               tools: [
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
                 %{
                   "name" => "remote.internal",
                   "annotations" => %{"userInvocable" => false}
                 }
               ]
             })

    assert entry.id == "mcp:remote-tools:remote.review"
    assert entry.name == "remote-review"
    assert entry.slash == "/remote-review"
    assert entry.source == :mcp
    assert entry.source_id == "remote-tools"
    assert entry.summary == "Review through a remote MCP server."
    assert entry.aliases == ["/rr"]

    assert entry.args == [
             %{name: "limit", required?: false, description: "Maximum issues"},
             %{name: "path", required?: true, description: "Path to review"}
           ]

    assert entry.run_spec.kind == :mcp_tool
    assert entry.run_spec.transport == :streamable_http
    assert entry.run_spec.method == "tools/call"
    assert entry.metadata.discovered_from == "tools/list"
    assert entry.metadata.invocability.source == :annotation_user_invocable
  end

  test "accepts direct tool maps and nested result envelopes" do
    direct =
      McpToolLoader.entries(%{
        name: "fs.search",
        input_schema: %{},
        source_id: "filesystem",
        transport: :stdio
      })

    nested =
      McpToolLoader.entries(%{
        transport: :sse,
        session_id: "agent-tools",
        result: %{
          tools: [
            %{
              name: "agent.summarize",
              args: [%{name: "child_id", required?: true, description: "Child session"}]
            }
          ]
        }
      })

    assert Enum.map(direct, & &1.slash) == ["/fs-search"]
    assert hd(direct).metadata.invocability.source == :default_user_invocable
    assert hd(direct).source_id == "filesystem"

    assert Enum.map(nested, & &1.slash) == ["/agent-summarize"]
    assert hd(nested).source_id == "agent-tools"
    assert hd(nested).args == [%{name: "child_id", required?: true, description: "Child session"}]
  end
end
