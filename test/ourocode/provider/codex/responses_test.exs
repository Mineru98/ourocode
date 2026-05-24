defmodule Ourocode.Provider.Codex.ResponsesTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Codex.Responses

  test "request_body builds the Responses API user turn" do
    body = Responses.request_body("hello", "gpt-5.3-codex", "sys")

    assert body["model"] == "gpt-5.3-codex"
    assert body["instructions"] == "sys"
    assert body["stream"] == true
    assert body["store"] == false

    assert body["input"] == [
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "hello"}]}
           ]
  end

  test "text_delta extracts only output_text deltas" do
    assert Responses.text_delta(%{"type" => "response.output_text.delta", "delta" => "Hi"}) ==
             "Hi"

    assert Responses.text_delta(%{"type" => "response.created"}) == nil
    assert Responses.text_delta(%{"type" => "response.output_text.delta"}) == nil
  end

  test "terminal? detects completion events" do
    assert Responses.terminal?(%{"type" => "response.completed"})
    assert Responses.terminal?(%{"type" => "response.failed"})
    assert Responses.terminal?(%{"type" => "response.incomplete"})
    refute Responses.terminal?(%{"type" => "response.output_text.delta"})
  end

  test "parse_sse splits complete frames and keeps a partial tail" do
    chunk =
      ~s(data: {"type":"response.output_text.delta","delta":"He"}\n\n) <>
        ~s(data: {"type":"response.output_text.delta","delta":"llo"}\n\n) <>
        ~s(data: {"type":"response.comp)

    {events, rest} = Responses.parse_sse(chunk)

    assert Enum.map(events, &Responses.text_delta/1) == ["He", "llo"]
    assert rest == ~s(data: {"type":"response.comp)

    {events2, rest2} = Responses.parse_sse(rest <> ~s(leted"}\n\n))
    assert Enum.any?(events2, &Responses.terminal?/1)
    assert rest2 == ""
  end

  test "parse_sse ignores [DONE], malformed JSON, and non-data lines" do
    chunk =
      "event: ping\n" <>
        "data: [DONE]\n\n" <>
        "data: not-json\n\n" <>
        "data: {\"type\":\"response.created\"}\n\n"

    assert {[%{"type" => "response.created"}], ""} = Responses.parse_sse(chunk)
  end
end
