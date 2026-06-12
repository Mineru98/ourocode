defmodule Ourocode.Provider.Anthropic.AuthTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Anthropic.Auth

  test "generate_pkce produces a url-safe verifier and its S256 challenge" do
    %{verifier: verifier, challenge: challenge} = Auth.generate_pkce()

    assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
    assert challenge =~ ~r/^[A-Za-z0-9_-]+$/

    expected = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    assert challenge == expected
  end

  test "authorize_url targets claude.ai with PKCE and the inference scope" do
    url = Auth.authorize_url("CHALLENGE", "STATE")
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.host == "claude.ai"
    assert uri.path == "/oauth/authorize"
    assert query["code_challenge"] == "CHALLENGE"
    assert query["code_challenge_method"] == "S256"
    assert query["state"] == "STATE"
    assert query["client_id"] == Auth.client_id()
    assert query["redirect_uri"] == Auth.redirect_uri()
    assert query["scope"] =~ "user:inference"
  end

  test "client_id decodes to the Claude CLI OAuth client" do
    assert Auth.client_id() == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  end
end
