defmodule Ourocode.MCP.CallRuntimeTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.CallRuntime

  test "builds JSON-RPC tools/call requests" do
    assert CallRuntime.tools_call_request("ouroboros_auto", %{"goal" => "build"}, "call-42") == %{
             "jsonrpc" => "2.0",
             "id" => "call-42",
             "method" => "tools/call",
             "params" => %{
               "name" => "ouroboros_auto",
               "arguments" => %{"goal" => "build"}
             }
           }
  end

  test "executes tool calls as parent calls through the configured transport" do
    executor = fn options, request ->
      send(self(), {:executed_parent_call, options, request})
      {:ok, %{status: 202}}
    end

    assert {:ok, %{status: 202}} =
             CallRuntime.execute_tool_call(
               [url: "http://127.0.0.1:4010/mcp", parent_call_id: "parent-tool-1"],
               "ouroboros_ralph",
               %{"lineage_id" => "lin-1"},
               request_id: "request-1",
               execute_parent_call: executor
             )

    assert_receive {:executed_parent_call, options, request}

    assert Keyword.fetch!(options, :parent_call_id) == "parent-tool-1"
    assert Keyword.fetch!(options, :runtime_source) == "ouroboros"

    assert request == %{
             "jsonrpc" => "2.0",
             "id" => "request-1",
             "method" => "tools/call",
             "params" => %{
               "name" => "ouroboros_ralph",
               "arguments" => %{"lineage_id" => "lin-1"}
             }
           }
  end

  test "derives stable parent call ids from tool names when none is supplied" do
    assert CallRuntime.parent_call_id([], "ouroboros/auto run") ==
             "parent-mcp-tool-ouroboros-auto-run"
  end
end
