defmodule Ourocode.Provider.Anthropic.MessagesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Anthropic.Messages

  test "request_body puts the Claude Code instruction first and streams" do
    input = [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}]
    body = Messages.request_body(input, "claude-sonnet-4-6", 4096)

    assert body["model"] == "claude-sonnet-4-6"
    assert body["max_tokens"] == 4096
    assert body["stream"] == true
    assert body["messages"] == input

    # The subscription endpoint requires this exact first system block.
    assert [%{"type" => "text", "text" => first} | _] = body["system"]
    assert first == Messages.claude_code_system()
  end

  test "request_body appends caller system text after the required block" do
    body = Messages.request_body([], "m", 10, "be terse")

    assert [%{"text" => first}, %{"text" => "be terse"}] = body["system"]
    assert first == Messages.claude_code_system()
  end

  test "messages renders alternating roles ending with the current prompt" do
    assert Messages.messages([{"q1", "a1"}], "q2") == [
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "q1"}]},
             %{"role" => "assistant", "content" => [%{"type" => "text", "text" => "a1"}]},
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "q2"}]}
           ]
  end

  test "text_delta extracts only content_block_delta text deltas" do
    assert Messages.text_delta(%{
             "type" => "content_block_delta",
             "delta" => %{"type" => "text_delta", "text" => "Hi"}
           }) == "Hi"

    assert Messages.text_delta(%{"type" => "message_start"}) == nil
    assert Messages.text_delta(%{"type" => "content_block_delta", "delta" => %{"type" => "input_json_delta"}}) == nil
  end

  test "terminal? detects message_stop and error" do
    assert Messages.terminal?(%{"type" => "message_stop"})
    assert Messages.terminal?(%{"type" => "error"})
    refute Messages.terminal?(%{"type" => "content_block_delta"})
  end

  test "parse_sse splits event/data frames and keeps a partial tail" do
    chunk =
      "event: content_block_delta\n" <>
        ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"He"}}\n\n) <>
        ~s(data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"llo"}}\n\n) <>
        ~s(data: {"type":"message_st)

    {events, rest} = Messages.parse_sse(chunk)

    assert Enum.map(events, &Messages.text_delta/1) == ["He", "llo"]
    assert rest =~ "message_st"
  end
end
