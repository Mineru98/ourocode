defmodule Ourocode.Acp.ProtocolTest do
  use ExUnit.Case, async: true

  alias Ourocode.Acp.Protocol
  alias Ourocode.Json

  test "decode distinguishes requests, notifications, and invalid frames" do
    assert {:request, 1, "initialize", %{"protocolVersion" => 1}} =
             Protocol.decode(~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}))

    assert {:notification, "session/cancel", %{"sessionId" => "s"}} =
             Protocol.decode(~s({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}}))

    assert {:request, 2, "initialize", %{}} =
             Protocol.decode(~s({"jsonrpc":"2.0","id":2,"method":"initialize"}))

    assert {:invalid, 3} = Protocol.decode(~s({"jsonrpc":"2.0","id":3}))
    assert {:invalid, nil} = Protocol.decode("not json at all")
  end

  test "result, error, and notification frames are single-line JSON-RPC" do
    for frame <- [
          Protocol.result(1, %{"ok" => true}),
          Protocol.error(2, -32601, "nope"),
          Protocol.notification("session/update", %{"sessionId" => "s"}),
          Protocol.agent_message_chunk("s", "multi\nline\ntext")
        ] do
      refute frame =~ "\n"
      assert {:ok, %{"jsonrpc" => "2.0"}} = Json.decode(frame)
    end
  end

  test "agent_message_chunk carries the streamed text content block" do
    {:ok, frame} = Json.decode(Protocol.agent_message_chunk("sess_1", "hello"))

    assert frame["method"] == "session/update"
    assert frame["params"]["sessionId"] == "sess_1"

    assert frame["params"]["update"] == %{
             "sessionUpdate" => "agent_message_chunk",
             "content" => %{"type" => "text", "text" => "hello"}
           }
  end

  test "initialize_result advertises baseline text-only capabilities" do
    result = Protocol.initialize_result("0.1.13")

    assert result["protocolVersion"] == Protocol.protocol_version()
    assert result["agentInfo"]["name"] == "ourocode"
    assert result["agentInfo"]["version"] == "0.1.13"
    assert result["agentCapabilities"]["loadSession"] == false
    assert result["agentCapabilities"]["promptCapabilities"]["image"] == false
    assert result["authMethods"] == []
  end

  test "prompt_text joins text blocks and ignores other content types" do
    params = %{
      "prompt" => [
        %{"type" => "text", "text" => "first"},
        %{"type" => "image", "data" => "...", "mimeType" => "image/png"},
        %{"type" => "text", "text" => "second"}
      ]
    }

    assert Protocol.prompt_text(params) == "first\nsecond"
    assert Protocol.prompt_text(%{}) == ""
  end
end
