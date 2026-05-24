defmodule Ourocode.Provider.Codex.AuthTest do
  use ExUnit.Case, async: false

  alias Ourocode.Provider.Codex.Auth
  alias Ourocode.Provider.Codex.Store

  test "authorization returns stored unexpired access token metadata" do
    with_tmp_home(fn ->
      expires = System.system_time(:millisecond) + 60_000
      tokens = %{access: "ac", refresh: "rf", expires: expires, account_id: "acc"}

      assert :ok = Store.save(tokens)
      assert Auth.authorization() == {:ok, %{access: "ac", account_id: "acc"}}
    end)
  end

  test "authorization fails instead of returning expired access when refresh is unavailable" do
    with_tmp_home(fn ->
      tokens = %{access: "expired", refresh: "", expires: 0, account_id: "acc"}

      assert :ok = Store.save(tokens)
      assert Auth.authorization() == :error
    end)
  end

  test "api_headers include Codex auth, origin, session, and optional account id" do
    assert Auth.api_headers("tok", "acc-1", "session-1") == [
             {"authorization", "Bearer tok"},
             {"content-type", "application/json"},
             {"accept", "text/event-stream"},
             {"originator", "ourocode"},
             {"user-agent", "ourocode/0.1.0"},
             {"session_id", "session-1"},
             {"ChatGPT-Account-Id", "acc-1"}
           ]

    refute Enum.any?(Auth.api_headers("tok", nil, "session-1"), fn {key, _value} ->
             key == "ChatGPT-Account-Id"
           end)
  end

  defp with_tmp_home(fun) do
    tmp_home =
      Path.join(
        System.tmp_dir!(),
        "ourocode-codex-auth-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_home)
    original = System.get_env("HOME")
    System.put_env("HOME", tmp_home)

    try do
      fun.()
    after
      if original, do: System.put_env("HOME", original), else: System.delete_env("HOME")
      File.rm_rf(tmp_home)
    end
  end
end
