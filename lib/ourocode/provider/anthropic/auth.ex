defmodule Ourocode.Provider.Anthropic.Auth do
  @moduledoc """
  Anthropic (Claude Pro/Max) OAuth: PKCE authorization-code flow matching
  Claude Code's browser + manual code-paste flow.

  This connects the main session to a user's Claude subscription through the
  same OAuth client the Claude CLI uses. Tokens are minted and refreshed
  against `platform.claude.com/v1/oauth/token`.
  """

  alias Ourocode.Provider.Anthropic.HTTP
  alias Ourocode.Provider.Anthropic.Store
  alias Ourocode.Provider.Anthropic.Token

  # The OAuth client id the Claude CLI ships, base64 as in upstream clients.
  @client_id Base.decode64!("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl")
  @authorize_url "https://claude.com/cai/oauth/authorize"
  @token_url "https://platform.claude.com/v1/oauth/token"
  @redirect_uri "https://platform.claude.com/oauth/code/callback"
  @scopes "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  @refresh_skew_ms 5 * 60_000

  @type pkce :: %{verifier: String.t(), challenge: String.t()}

  @doc "Generates a PKCE verifier/challenge pair (S256)."
  @spec generate_pkce() :: pkce()
  def generate_pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    %{verifier: verifier, challenge: challenge}
  end

  @doc """
  Builds the browser authorization URL. `state` doubles as the PKCE binding
  the user echoes back; callers persist `pkce.verifier` for the exchange.
  """
  @spec authorize_url(String.t(), String.t()) :: String.t()
  def authorize_url(challenge, state) when is_binary(challenge) and is_binary(state) do
    authorize_url(challenge, state, @redirect_uri)
  end

  @doc false
  @spec authorize_url(String.t(), String.t(), String.t()) :: String.t()
  def authorize_url(challenge, state, redirect_uri)
      when is_binary(challenge) and is_binary(state) and is_binary(redirect_uri) do
    query =
      URI.encode_query([
        {"code", "true"},
        {"client_id", @client_id},
        {"response_type", "code"},
        {"redirect_uri", redirect_uri},
        {"scope", @scopes},
        {"code_challenge", challenge},
        {"code_challenge_method", "S256"},
        {"state", state}
      ])

    @authorize_url <> "?" <> query
  end

  @doc """
  Exchanges a pasted authorization code for tokens and persists them. The
  Claude callback returns `code#state`; either form is accepted.
  """
  @spec exchange(String.t(), String.t(), String.t()) :: {:ok, Token.tokens()} | {:error, term()}
  def exchange(pasted_code, verifier, state) do
    exchange(pasted_code, verifier, state, @redirect_uri)
  end

  @doc false
  @spec exchange(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Token.tokens()} | {:error, term()}
  def exchange(pasted_code, verifier, state, redirect_uri)
      when is_binary(redirect_uri) do
    {code, code_state} = split_code(pasted_code, state)

    body = %{
      "grant_type" => "authorization_code",
      "client_id" => @client_id,
      "code" => code,
      "state" => code_state,
      "redirect_uri" => redirect_uri,
      "code_verifier" => verifier
    }

    case HTTP.json(:post, @token_url, body) do
      {:ok, 200, %{} = resp} ->
        tokens = Token.from_response(resp, now_ms())
        :ok = Store.save(tokens)
        {:ok, tokens}

      {:ok, status, resp} ->
        {:error, {:token_exchange_failed, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Refreshes and persists tokens using the stored refresh token."
  @spec refresh(Token.tokens()) :: {:ok, Token.tokens()} | {:error, term()}
  def refresh(%{refresh: refresh}) when is_binary(refresh) and refresh != "" do
    body = %{
      "grant_type" => "refresh_token",
      "client_id" => @client_id,
      "refresh_token" => refresh
    }

    case HTTP.json(:post, @token_url, body) do
      {:ok, 200, %{} = resp} ->
        merged =
          resp
          |> Token.from_response(now_ms())
          |> then(fn t -> if t.refresh in [nil, ""], do: %{t | refresh: refresh}, else: t end)

        :ok = Store.save(merged)
        {:ok, merged}

      {:ok, status, resp} ->
        {:error, {:token_refresh_failed, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh(_tokens), do: {:error, :no_refresh_token}

  @doc """
  Returns a valid access token for an API call, refreshing predictively when
  it is within the skew window. `:error` when not signed in or unrecoverable.
  """
  @spec authorization() :: {:ok, String.t()} | :error
  def authorization do
    with {:ok, tokens} <- Store.load() do
      case valid_access(tokens) do
        {:ok, access} -> {:ok, access}
        :error -> :error
      end
    else
      _ -> :error
    end
  end

  @doc false
  @spec client_id() :: String.t()
  def client_id, do: @client_id

  @doc false
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  defp valid_access(tokens) do
    now = now_ms()

    tokens =
      if Token.expired?(tokens, now + @refresh_skew_ms) do
        case refresh(tokens) do
          {:ok, refreshed} -> refreshed
          {:error, _reason} -> if Token.expired?(tokens, now), do: nil, else: tokens
        end
      else
        tokens
      end

    case tokens do
      %{access: access} when is_binary(access) and access != "" -> {:ok, access}
      _ -> :error
    end
  end

  # The Claude callback returns `code#state`; prefer the embedded state.
  defp split_code(pasted, fallback_state) do
    case String.split(pasted, "#", parts: 2) do
      [code, state] when state != "" -> {code, state}
      [code | _] -> {code, fallback_state}
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
