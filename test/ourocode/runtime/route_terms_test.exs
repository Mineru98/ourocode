defmodule Ourocode.Runtime.RouteTermsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.RouteTerms

  test "normalizes and tokenizes route input" do
    assert RouteTerms.normalize("  MCP\n tools/call\t over HTTP  ") ==
             "MCP tools/call over HTTP"

    assert RouteTerms.tokens("MCP tools/call over streamable HTTP!") == [
             "mcp",
             "tools/call",
             "over",
             "streamable",
             "http"
           ]
  end

  test "detects mcp flow terms and explicit mcp shortcuts" do
    assert RouteTerms.mcp_flow?(["please", "mcp:stdio"])
    assert RouteTerms.mcp_flow?(["json-rpc"])
    assert RouteTerms.explicit_mcp_shortcut?(["tools/call", "list"])
    refute RouteTerms.explicit_mcp_shortcut?(["please", "mcp"])
  end

  test "detects explicit runtime shortcuts" do
    assert RouteTerms.explicit_diagnostics_shortcut?(["diagnostics:streams"])
    assert RouteTerms.explicit_test_shortcut?(["test:transport"])
    refute RouteTerms.explicit_diagnostics_shortcut?(["please", "diagnostics"])
    refute RouteTerms.explicit_test_shortcut?(["please", "test:transport"])
  end

  test "detects ouroboros workflow terms and adapter routes" do
    assert RouteTerms.ouroboros_workflow?(["please", "ouroboros:evolve"])
    assert RouteTerms.ouroboros_adapter_route(["ooo", "run", "seed_path=seed.md"]) == :run
    assert RouteTerms.ouroboros_adapter_route(["ouroboros", "execute", "seed.md"]) == :run
    assert RouteTerms.ouroboros_adapter_route(["please", "ralph"]) == :ralph
    assert RouteTerms.ouroboros_adapter_route(["please", "workflow"]) == :workflow
    assert RouteTerms.ouroboros_adapter_route(["please", "other"]) == :workflow
  end

  test "extracts transport hints from tokens" do
    assert RouteTerms.transport_from_tokens(["mcp:stdio"]) == :stdio
    assert RouteTerms.transport_from_tokens(["sse"]) == :sse
    assert RouteTerms.transport_from_tokens(["streamable-http"]) == :streamable_http
    assert RouteTerms.transport_from_tokens(["http"]) == :streamable_http
    assert RouteTerms.transport_from_tokens(["plain", "prompt"]) == :auto
  end
end
