defmodule Ourocode.Provider.Anthropic.AuthTest do
  use ExUnit.Case, async: true

  alias Ourocode.Provider.Anthropic.Auth

  test "generate_pkce produces a url-safe verifier and its S256 challenge" do
    %{verifier: verifier, challenge: challenge} = Auth.generate_pkce()

    assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
    assert challenge =~ ~r/^[A-Za-z0-9_-]+$/
    assert String.length(verifier) == 43
    assert String.length(challenge) == 43

    expected = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    assert challenge == expected
  end

  test "authorize_url targets Claude Code OAuth with PKCE and the official scope" do
    url = Auth.authorize_url("CHALLENGE", "STATE")
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "claude.com"
    assert uri.path == "/cai/oauth/authorize"
    assert query["code_challenge"] == "CHALLENGE"
    assert query["code_challenge_method"] == "S256"
    assert query["state"] == "STATE"
    assert query["client_id"] == Auth.client_id()
    assert query["redirect_uri"] == Auth.redirect_uri()

    assert query["scope"] ==
             "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  end

  test "authorize_url uses Claude's hosted callback redirect URI" do
    url = Auth.authorize_url("CHALLENGE", "STATE")
    query = URI.decode_query(URI.parse(url).query)

    assert query["redirect_uri"] == "https://platform.claude.com/oauth/code/callback"
  end

  test "client_id decodes to the Claude CLI OAuth client" do
    assert Auth.client_id() == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  end
end
