defmodule Ourocode.Provider.Codex.HTTPTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Codex.HTTP

  test "decode_body decodes JSON objects" do
    assert HTTP.decode_body(~s({"access_token":"tok","expires_in":3600})) == %{
             "access_token" => "tok",
             "expires_in" => 3600
           }
  end

  test "decode_body preserves non-object and malformed bodies as raw text" do
    assert HTTP.decode_body(~s(["not","object"])) == %{"raw" => ~s(["not","object"])}
    assert HTTP.decode_body("not json") == %{"raw" => "not json"}
  end

  test "decode_body treats non-binary bodies as empty response maps" do
    assert HTTP.decode_body(nil) == %{}
    assert HTTP.decode_body(:closed) == %{}
  end
end
