defmodule Ourocode.Provider.Anthropic.StoreTest do
  use ExUnit.Case, async: false

  alias Ourocode.Json
  alias Ourocode.Provider.Anthropic.Store

  test "save/load round-trips and signed_in? tracks usability" do
    with_tmp_home(fn ->
      live = System.system_time(:millisecond) + 600_000
      tokens = %{access: "ac", refresh: "rf", expires: live, account_id: "acc", email: "e@x.y"}

      assert :ok = Store.save(tokens)
      assert Store.signed_in?() == true
      assert {:ok, loaded} = Store.load()
      assert loaded.access == "ac"
      assert loaded.email == "e@x.y"

      assert :ok = Store.clear()
      assert Store.load() == :error
      assert Store.signed_in?() == false
    end)
  end

  test "signed_in? rejects an expired credential with no refresh token" do
    with_tmp_home(fn ->
      assert :ok = Store.save(%{access: "ac", refresh: "", expires: 0})
      assert Store.signed_in?() == false
    end)
  end

  test "save preserves a sibling provider's credentials in the shared file" do
    with_tmp_home(fn ->
      path = Store.store_path()
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Json.encode!(%{"codex" => %{"access" => "codex-token"}}))

      live = System.system_time(:millisecond) + 600_000
      assert :ok = Store.save(%{access: "claude-token", refresh: "rf", expires: live})

      {:ok, %{"codex" => codex, "anthropic" => anthropic}} = Json.decode(File.read!(path))
      assert codex["access"] == "codex-token"
      assert anthropic["access"] == "claude-token"
    end)
  end

  defp with_tmp_home(fun) do
    tmp_home =
      Path.join(System.tmp_dir!(), "ourocode-anthropic-store-#{System.unique_integer([:positive])}")

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
