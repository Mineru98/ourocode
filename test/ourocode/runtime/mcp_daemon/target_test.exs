defmodule Ourocode.Runtime.McpDaemon.TargetTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.McpDaemon.Target

  test "decide disables before considering explicit URLs" do
    assert Target.decide(true, "http://127.0.0.1:4999/mcp", fn _, _ -> true end, fn -> 4001 end) ==
             :disabled
  end

  test "decide adopts open explicit targets and spawns closed explicit targets" do
    assert Target.decide(
             false,
             "http://localhost:4999/mcp",
             fn "localhost", 4999 -> true end,
             fn ->
               4001
             end
           ) == {:external, "http://localhost:4999/mcp"}

    assert Target.decide(
             false,
             "http://localhost:4999/mcp",
             fn "localhost", 4999 -> false end,
             fn ->
               4001
             end
           ) == {:spawn, "localhost", 4999, "http://localhost:4999/mcp", true}
  end

  test "decide allocates a per-instance default target when no explicit URL is set" do
    assert Target.decide(false, nil, fn _, _ -> false end, fn -> 4567 end) ==
             {:spawn, "127.0.0.1", 4567, "http://127.0.0.1:4567/mcp", false}
  end

  test "host_port and url normalize target addresses" do
    assert Target.host_port("http://example.test:1234/mcp") == {"example.test", 1234}
    assert Target.host_port("http://127.0.0.1/mcp") == {"127.0.0.1", 80}
    assert Target.url("127.0.0.1", 7890) == "http://127.0.0.1:7890/mcp"
  end
end
