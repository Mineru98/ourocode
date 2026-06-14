defmodule Ourocode.Provider.Codex.StoreTest do
  use ExUnit.Case, async: false

  alias Ourocode.Json
  alias Ourocode.Provider.Codex.Store

  test "save/load round-trips, marks signed in, and clear removes credentials" do
    with_tmp_home(fn ->
      tokens = %{access: "ac", refresh: "rf", expires: 42, account_id: "acc", email: "e@x.y"}

      assert :ok = Store.save(tokens)
      assert Store.signed_in?() == true
      assert {:ok, loaded} = Store.load()
      assert loaded.access == "ac"
      assert loaded.refresh == "rf"
      assert loaded.expires == 42
      assert loaded.account_id == "acc"
      assert loaded.email == "e@x.y"

      assert :ok = Store.clear()
      assert Store.load() == :error
      assert Store.signed_in?() == false
    end)
  end

  test "load returns error for malformed or missing credential files" do
    with_tmp_home(fn ->
      assert Store.load() == :error

      Store.store_path()
      |> Path.dirname()
      |> File.mkdir_p!()

      File.write!(Store.store_path(), ~s({"other":{}}))
      assert Store.load() == :error

      File.write!(Store.store_path(), "not-json")
      assert Store.load() == :error
    end)
  end

  test "signed_in? requires a non-empty access token" do
    with_tmp_home(fn ->
      assert :ok = Store.save(%{access: "", refresh: "rf", expires: 42})
      assert Store.signed_in?() == false
    end)
  end

  test "signed_in? rejects an expired credential with no refresh token" do
    with_tmp_home(fn ->
      # An expired access token without a refresh token can never recover;
      # treating it as signed in would route turns onto a dead backend.
      assert :ok = Store.save(%{access: "ac", refresh: "", expires: 0})
      assert Store.signed_in?() == false

      live = System.system_time(:millisecond) + 600_000
      assert :ok = Store.save(%{access: "ac", refresh: "", expires: live})
      assert Store.signed_in?() == true
    end)
  end

  test "save and clear preserve a sibling provider's credentials in the shared file" do
    with_tmp_home(fn ->
      path = Store.store_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Json.encode!(%{"anthropic" => %{"access" => "claude-token"}}))

      live = System.system_time(:millisecond) + 600_000
      assert :ok = Store.save(%{access: "codex-token", refresh: "rf", expires: live})

      {:ok, %{"codex" => codex, "anthropic" => anthropic}} = Json.decode(File.read!(path))
      assert codex["access"] == "codex-token"
      assert anthropic["access"] == "claude-token"

      assert :ok = Store.clear()
      {:ok, remaining} = Json.decode(File.read!(path))
      refute Map.has_key?(remaining, "codex")
      assert remaining["anthropic"]["access"] == "claude-token"
    end)
  end

  defp with_tmp_home(fun) do
    tmp_home =
      Path.join(
        System.tmp_dir!(),
        "ourocode-codex-store-home-#{System.unique_integer([:positive])}"
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
