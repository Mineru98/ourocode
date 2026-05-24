defmodule Ourocode.MCP.RuntimeEventPathTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.RuntimeEventPath

  test "fetches supported paths through atom and string keys" do
    event = %{
      "raw_event" => %{
        event: %{
          "data" => %{
            params: %{"sessionID" => "session-1"}
          }
        }
      }
    }

    assert {:ok, %{"sessionID" => "session-1"}} =
             RuntimeEventPath.fetch(event, [:raw_event, :event, :data, :params])
  end

  test "returns error for missing paths and non-map traversal" do
    assert RuntimeEventPath.fetch(%{"raw_event" => "not-map"}, [:raw_event, :data]) == :error
    assert RuntimeEventPath.fetch(%{}, [:raw_event]) == :error
  end

  test "exposes stable container path groups" do
    assert [] in RuntimeEventPath.supported_containers()
    assert [:raw_event, :event, :data, :params] in RuntimeEventPath.supported_containers()
    assert [:params, :input] in RuntimeEventPath.input_containers()
    assert [:raw_event, :event, :data, :input] in RuntimeEventPath.input_containers()
  end
end
