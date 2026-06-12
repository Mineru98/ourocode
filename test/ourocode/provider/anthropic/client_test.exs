defmodule Ourocode.Provider.Anthropic.ClientTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Anthropic.Client

  test "headers present the Claude Code OAuth identity" do
    headers = Map.new(Client.headers("tok"))

    assert headers["authorization"] == "Bearer tok"
    assert headers["accept"] == "text/event-stream"
    assert headers["anthropic-version"] == "2023-06-01"
    assert headers["anthropic-beta"] =~ "oauth-2025-04-20"
    assert headers["user-agent"] =~ "claude-cli"
    assert headers["x-app"] == "cli"

    # OAuth uses a bearer token, never the API-key header.
    refute Map.has_key?(headers, "x-api-key")
  end

  test "stream reports not signed in without stored credentials" do
    # No Anthropic credentials in a fresh tmp home: the call must fail fast
    # rather than attempt the network.
    tmp_home =
      Path.join(System.tmp_dir!(), "ourocode-anthropic-client-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_home)
    original = System.get_env("HOME")
    System.put_env("HOME", tmp_home)

    try do
      assert {:error, :not_signed_in} = Client.stream("hi", [], fn _chunk -> :ok end)
    after
      if original, do: System.put_env("HOME", original), else: System.delete_env("HOME")
      File.rm_rf(tmp_home)
    end
  end
end
