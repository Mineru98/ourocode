defmodule Ourocode.Provider.Codex.TokenTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Codex.Token

  defp jwt(payload) do
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)

    body =
      payload
      |> Ourocode.Json.encode!()
      |> IO.iodata_to_binary()
      |> Base.url_encode64(padding: false)

    "#{header}.#{body}.sig"
  end

  describe "JWT claims" do
    test "parses a valid JWT payload" do
      token = jwt(%{"email" => "dev@example.com", "chatgpt_account_id" => "acc-1"})

      assert Token.parse_jwt_claims(token) == %{
               "email" => "dev@example.com",
               "chatgpt_account_id" => "acc-1"
             }
    end

    test "returns nil for malformed tokens" do
      assert Token.parse_jwt_claims("only.two") == nil
      assert Token.parse_jwt_claims("a.!!!.b") == nil
      assert Token.parse_jwt_claims(nil) == nil
    end
  end

  describe "account and email extraction" do
    test "prefers root account id, then nested auth metadata, then organizations" do
      assert Token.extract_account_id_from_claims(%{
               "chatgpt_account_id" => "root",
               "https://api.openai.com/auth" => %{"chatgpt_account_id" => "nested"}
             }) == "root"

      assert Token.extract_account_id_from_claims(%{
               "https://api.openai.com/auth" => %{"chatgpt_account_id" => "nested"}
             }) == "nested"

      assert Token.extract_account_id_from_claims(%{
               "organizations" => [%{"id" => "org-1"}, %{"id" => "org-2"}]
             }) == "org-1"
    end

    test "uses id_token before access_token" do
      assert Token.extract_account_id(%{
               "id_token" => jwt(%{"chatgpt_account_id" => "from-id"}),
               "access_token" => jwt(%{"chatgpt_account_id" => "from-access"})
             }) == "from-id"

      assert Token.extract_email(%{
               "id_token" => jwt(%{"email" => "dev@example.com"})
             }) == "dev@example.com"
    end
  end

  test "maps OAuth responses and detects expiration" do
    response = %{
      "access_token" => "ac",
      "refresh_token" => "rf",
      "expires_in" => 10,
      "id_token" => jwt(%{"email" => "dev@example.com", "chatgpt_account_id" => "acc"})
    }

    assert %{
             access: "ac",
             refresh: "rf",
             expires: 11_000,
             account_id: "acc",
             email: "dev@example.com"
           } = tokens = Token.from_response(response, 1_000)

    refute Token.expired?(tokens, 10_999)
    assert Token.expired?(tokens, 11_000)
    assert Token.expired?(%{access: "", refresh: "rf", expires: 11_000}, 10_999)
  end

  test "converts persisted token maps between string and atom keys" do
    stored = %{
      "access" => "ac",
      "refresh" => "rf",
      "expires" => 42,
      "account_id" => "acc",
      "email" => "dev@example.com"
    }

    assert %{
             access: "ac",
             refresh: "rf",
             expires: 42,
             account_id: "acc",
             email: "dev@example.com"
           } = tokens = Token.atomize(stored)

    assert Token.stringify(tokens) == stored
  end
end
