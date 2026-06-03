defmodule Ourocode.WonderTool.BridgeTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.Bridge
  alias Ourocode.WonderTool.InteractionDetector

  test "promotes MCP permission notifications into wonderTool detections" do
    event = %{
      type: :parent_call_event,
      parent_call_id: "parent-permission-1",
      runtime_source: "grok",
      transport: :stdio,
      external_ids: %{"childID" => "child-permission-1"},
      notification: %{
        "method" => "session/request_permission",
        "params" => %{
          "requestId" => "perm-1",
          "childID" => "child-permission-1",
          "description" => "Run `git diff`?"
        }
      }
    }

    assert {:ok, payload} = Bridge.to_detection_payload(event)
    assert {:ok, detection} = InteractionDetector.detect(payload)

    assert detection.type == :multiple_choice_checkpoint
    assert detection.request_id == "perm-1"
    assert detection.parent_call_id == "parent-permission-1"
    assert detection.child_id == "child-permission-1"

    assert [%{kind: :permission, question: "Run `git diff`?", options: options}] =
             detection.request.questions

    assert Enum.map(options, & &1.label) == ["Allow (Recommended)", "Deny"]
  end

  test "ignores ordinary MCP notifications" do
    assert Bridge.to_detection_payload(%{notification: %{"method" => "session/update"}}) ==
             :ignore
  end
end
