defmodule Ourocode.Provider.Codex.StoreTest do
  use ExUnit.Case, async: false

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
