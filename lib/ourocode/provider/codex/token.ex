defmodule Ourocode.Provider.Codex.Token do
  @moduledoc """
  Pure Codex OAuth token helpers.
  """

  alias Ourocode.Json

  @type tokens :: %{
          required(:access) => String.t(),
          required(:refresh) => String.t(),
          required(:expires) => integer(),
          optional(:account_id) => String.t() | nil,
          optional(:email) => String.t() | nil
        }

  @doc "Decodes the JWT payload claims, or `nil` for a malformed token."
  @spec parse_jwt_claims(String.t() | nil) :: map() | nil
  def parse_jwt_claims(token) when is_binary(token) do
    case String.split(token, ".") do
      [_header, payload, _sig] ->
        with {:ok, json} <- base64url_decode(payload),
             {:ok, claims} when is_map(claims) <- Json.decode(json) do
          claims
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def parse_jwt_claims(_token), do: nil

  @doc "Extracts the ChatGPT account id from JWT claims with opencode precedence."
  @spec extract_account_id_from_claims(map()) :: String.t() | nil
  def extract_account_id_from_claims(%{} = claims) do
    nested = claims["https://api.openai.com/auth"]
    org = claims["organizations"]

    cond do
      is_binary(claims["chatgpt_account_id"]) -> claims["chatgpt_account_id"]
      is_map(nested) and is_binary(nested["chatgpt_account_id"]) -> nested["chatgpt_account_id"]
      is_list(org) and match?([%{"id" => id} | _] when is_binary(id), org) -> hd(org)["id"]
      true -> nil
    end
  end

  @doc "Resolves the account id from a token response (id_token then access_token)."
  @spec extract_account_id(map()) :: String.t() | nil
  def extract_account_id(%{} = token_response) do
    from(token_response["id_token"]) || from(token_response["access_token"])
  end

  @doc "Email claim from the id_token, if present."
  @spec extract_email(map()) :: String.t() | nil
  def extract_email(%{} = token_response) do
    case parse_jwt_claims(token_response["id_token"] || token_response["access_token"]) do
      %{"email" => email} when is_binary(email) -> email
      _ -> nil
    end
  end

  @doc "Builds the token response into the stored token shape."
  @spec from_response(map(), integer()) :: tokens()
  def from_response(%{} = resp, now_ms) do
    %{
      access: resp["access_token"],
      refresh: resp["refresh_token"],
      expires: now_ms + (resp["expires_in"] || 3600) * 1000,
      account_id: extract_account_id(resp),
      email: extract_email(resp)
    }
  end

  @doc "True when the access token is missing or past its expiry."
  @spec expired?(tokens(), integer()) :: boolean()
  def expired?(%{access: access, expires: expires}, now_ms)
      when is_binary(access) and access != "" and is_integer(expires) do
    expires <= now_ms
  end

  def expired?(_tokens, _now_ms), do: true

  @doc """
  True when the stored credential can still serve a call: a live access
  token, or an expired one with a refresh token to mint a replacement.
  An expired token without a refresh token can never recover and must not
  count as signed in.
  """
  @spec usable?(tokens(), integer()) :: boolean()
  def usable?(%{access: access} = tokens, now_ms) when is_binary(access) and access != "" do
    not expired?(tokens, now_ms) or
      match?(%{refresh: refresh} when is_binary(refresh) and refresh != "", tokens)
  end

  def usable?(_tokens, _now_ms), do: false

  @spec atomize(map()) :: tokens()
  def atomize(%{} = tokens) do
    %{
      access: tokens["access"],
      refresh: tokens["refresh"],
      expires: tokens["expires"] || 0,
      account_id: tokens["account_id"],
      email: tokens["email"]
    }
  end

  @spec stringify(map()) :: map()
  def stringify(%{} = tokens) do
    %{
      "access" => tokens.access,
      "refresh" => tokens.refresh,
      "expires" => tokens.expires,
      "account_id" => Map.get(tokens, :account_id),
      "email" => Map.get(tokens, :email)
    }
  end

  defp from(token) do
    case parse_jwt_claims(token) do
      %{} = claims -> extract_account_id_from_claims(claims)
      _ -> nil
    end
  end

  defp base64url_decode(str) do
    padded =
      case rem(byte_size(str), 4) do
        0 -> str
        n -> str <> String.duplicate("=", 4 - n)
      end

    padded
    |> String.replace("-", "+")
    |> String.replace("_", "/")
    |> Base.decode64()
  end
end
