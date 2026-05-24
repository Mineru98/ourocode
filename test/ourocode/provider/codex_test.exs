defmodule Ourocode.Provider.CodexTest do
  use ExUnit.Case, async: false

  alias Ourocode.Provider.Codex

  defp jwt(payload) do
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)

    body =
      Base.url_encode64(Ourocode.Json.encode!(payload) |> IO.iodata_to_binary(), padding: false)

    "#{header}.#{body}.sig"
  end

  describe "parse_jwt_claims/1" do
    test "parses a valid JWT payload" do
      token = jwt(%{"email" => "dev@example.com", "chatgpt_account_id" => "acc-1"})

      assert Codex.parse_jwt_claims(token) == %{
               "email" => "dev@example.com",
               "chatgpt_account_id" => "acc-1"
             }
    end

    test "returns nil for malformed tokens" do
      assert Codex.parse_jwt_claims("only.two") == nil
      assert Codex.parse_jwt_claims("a.!!!.b") == nil
      assert Codex.parse_jwt_claims(nil) == nil
    end
  end

  describe "extract_account_id_from_claims/1" do
    test "prefers root chatgpt_account_id" do
      assert Codex.extract_account_id_from_claims(%{
               "chatgpt_account_id" => "root",
               "https://api.openai.com/auth" => %{"chatgpt_account_id" => "nested"}
             }) == "root"
    end

    test "falls back to nested then organizations" do
      assert Codex.extract_account_id_from_claims(%{
               "https://api.openai.com/auth" => %{"chatgpt_account_id" => "nested"}
             }) == "nested"

      assert Codex.extract_account_id_from_claims(%{
               "organizations" => [%{"id" => "org-1"}, %{"id" => "org-2"}]
             }) == "org-1"

      assert Codex.extract_account_id_from_claims(%{"email" => "x@y.z"}) == nil
    end
  end

  describe "extract_account_id/1" do
    test "uses id_token first, then access_token" do
      assert Codex.extract_account_id(%{
               "id_token" => jwt(%{"chatgpt_account_id" => "from-id"}),
               "access_token" => jwt(%{"chatgpt_account_id" => "from-access"})
             }) == "from-id"

      assert Codex.extract_account_id(%{
               "id_token" => jwt(%{"email" => "x@y.z"}),
               "access_token" => jwt(%{"chatgpt_account_id" => "from-access"})
             }) == "from-access"
    end
  end

  describe "tokens_from_response/2 and expired?/2" do
    test "maps an OAuth token response and computes expiry" do
      resp = %{
        "access_token" => "ac",
        "refresh_token" => "rf",
        "expires_in" => 3600,
        "id_token" => jwt(%{"email" => "dev@example.com", "chatgpt_account_id" => "acc"})
      }

      tokens = Codex.tokens_from_response(resp, 1_000)

      assert tokens.access == "ac"
      assert tokens.refresh == "rf"
      assert tokens.expires == 1_000 + 3_600_000
      assert tokens.account_id == "acc"
      assert tokens.email == "dev@example.com"

      refute Codex.expired?(tokens, tokens.expires - 1)
      assert Codex.expired?(tokens, tokens.expires)
      assert Codex.expired?(%{access: "", refresh: "x", expires: 0}, 1)
    end
  end

  describe "credential store" do
    test "save/load round-trips and clear removes it" do
      tmp_home =
        Path.join(System.tmp_dir!(), "ourocode-home-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)
      original = System.get_env("HOME")
      System.put_env("HOME", tmp_home)

      on_exit(fn ->
        if original, do: System.put_env("HOME", original)
        File.rm_rf(tmp_home)
      end)

      tokens = %{access: "ac", refresh: "rf", expires: 42, account_id: "acc", email: "e@x.y"}

      assert :ok = Codex.save(tokens)
      assert Codex.signed_in?() == true
      assert {:ok, loaded} = Codex.load()
      assert loaded.access == "ac"
      assert loaded.account_id == "acc"

      assert :ok = Codex.clear()
      assert Codex.load() == :error
      assert Codex.signed_in?() == false
    end

    test "authorization fails instead of returning expired access token when refresh cannot run" do
      tmp_home =
        Path.join(
          System.tmp_dir!(),
          "ourocode-expired-home-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_home)
      original = System.get_env("HOME")
      System.put_env("HOME", tmp_home)

      on_exit(fn ->
        if original, do: System.put_env("HOME", original)
        File.rm_rf(tmp_home)
      end)

      tokens = %{access: "expired", refresh: "", expires: 0, account_id: "acc", email: "e@x.y"}

      assert :ok = Codex.save(tokens)
      assert Codex.authorization() == :error
    end
  end

  describe "api_headers/3" do
    test "includes bearer, originator, and account id when present" do
      headers = Codex.api_headers("tok", "acc-9", "sess-1")

      assert {"authorization", "Bearer tok"} in headers
      assert {"originator", "ourocode"} in headers
      assert {"ChatGPT-Account-Id", "acc-9"} in headers
      assert {"session_id", "sess-1"} in headers
    end

    test "omits account id header when absent" do
      headers = Codex.api_headers("tok", nil, "sess-1")
      refute Enum.any?(headers, fn {k, _} -> k == "ChatGPT-Account-Id" end)
    end
  end
end
