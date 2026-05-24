defmodule Ourocode.Command.Registry.QueryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Command.Registry.Query
  alias Ourocode.Command.RegistryEntryAdapter

  test "normalizes supported filters and ignores invalid filters" do
    filters =
      Query.normalize_filters(
        source: :builtin,
        sources: [:mcp],
        category: :discovery,
        categories: [:skills],
        transport: "streamable-http",
        transports: ["stdio", :sse],
        plugin_id: :vim,
        plugin_ids: ["agent", :motion],
        source_id: :runtime,
        source_ids: ["local", :bundled],
        type: :slash_command,
        types: [:slash_command],
        prefix: "vim",
        query: " Child Agent ",
        text: " Remote Review ",
        availability: :available,
        runnable?: true,
        limit: 3,
        ignored: true,
        limit: 0,
        runnable?: "true"
      )

    assert {:sources, MapSet.new([:builtin])} in filters
    assert {:sources, MapSet.new([:mcp])} in filters
    assert {:categories, MapSet.new([:discovery])} in filters
    assert {:categories, MapSet.new([:skills])} in filters
    assert {:transports, MapSet.new([:streamable_http])} in filters
    assert {:transports, MapSet.new([:stdio, :sse])} in filters
    assert {:plugin_ids, MapSet.new(["vim"])} in filters
    assert {:plugin_ids, MapSet.new(["agent", "motion"])} in filters
    assert {:source_ids, MapSet.new(["runtime"])} in filters
    assert {:source_ids, MapSet.new(["local", "bundled"])} in filters
    assert {:types, MapSet.new([:slash_command])} in filters
    assert {:prefix, "/vim"} in filters
    assert {:query, "child agent"} in filters
    assert {:query, "remote review"} in filters
    assert {:availability, :available} in filters
    assert {:runnable?, true} in filters
    assert {:limit, 3} in filters
    refute Keyword.has_key?(filters, :ignored)
  end

  test "runs combined source, prefix, search, transport, plugin, and limit filters" do
    registry = %{ordered: [entry(:vim_help), entry(:remote_review), entry(:billing_stub)]}

    assert Query.run(registry, sources: [:plugin], prefix: "vim", text: "motion", limit: 1)
           |> Enum.map(& &1.slash) == ["/vim-help"]

    assert Query.run(registry, transport: "streamable-http", source_id: "remote-tools")
           |> Enum.map(& &1.slash) == ["/remote-review"]

    assert Query.run(registry, plugin_id: "vim-mode", query: "vim_motion_help")
           |> Enum.map(& &1.slash) == ["/vim-help"]

    assert Query.run(registry, availability: :stub, runnable?: false)
           |> Enum.map(& &1.slash) == ["/billing"]
  end

  defp entry(:vim_help) do
    RegistryEntryAdapter.from_skill_definition!(
      %{
        "id" => "vim-help",
        "name" => "vim-motion-help",
        "slash" => "/vim-help",
        "description" => "Show plugin-provided vim motion guidance.",
        "aliases" => ["/vim-motions"],
        "args" => [%{"name" => "topic", "description" => "Motion topic"}],
        "mcp_tool" => "vim_motion_help"
      },
      id: "plugin:vim-mode:vim-help",
      source: :plugin,
      source_id: "vim-mode",
      distribution: :plugin,
      run_kind: :plugin_skill,
      source_attribution: %{source: :plugin, source_id: "vim-mode", plugin_id: "vim-mode"},
      run_spec: %{kind: :plugin_skill, plugin_id: "vim-mode", mcp_tool: "vim_motion_help"},
      metadata: %{plugin_id: "vim-mode", command_namespace: "plugin:community:vim-mode"}
    )
  end

  defp entry(:remote_review) do
    RegistryEntryAdapter.from_skill_definition!(
      %{
        "id" => "remote-review",
        "name" => "remote-review",
        "slash" => "/remote-review",
        "description" => "Review through a remote MCP server.",
        "mcp_tool" => "remote.review"
      },
      id: "mcp:remote-tools:remote-review",
      source: :mcp,
      source_id: "remote-tools",
      distribution: :runtime,
      run_kind: :mcp_tool,
      source_attribution: %{source: :mcp, source_id: "remote-tools", transport: :streamable_http},
      run_spec: %{kind: :mcp_tool, server_id: "remote-tools", transport: :streamable_http}
    )
  end

  defp entry(:billing_stub) do
    RegistryEntryAdapter.from_slash_command!(
      %{
        name: "Billing",
        slash: "/billing",
        summary: "Out-of-scope provider billing placeholder.",
        run_spec: %{kind: :stub, reason: :provider_account_out_of_scope}
      },
      id: "stub:/billing",
      source: :dynamic_skill,
      source_id: "runtime-stubs",
      category: :provider_account,
      availability: :stub,
      runnable?: false
    )
  end
end
