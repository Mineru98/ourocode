defmodule Ourocode.Provider.Anthropic.Token do
  @moduledoc "Pure Anthropic OAuth token helpers."

  @type tokens :: %{
          required(:access) => String.t(),
          required(:refresh) => String.t(),
          required(:expires) => integer(),
          optional(:account_id) => String.t() | nil,
          optional(:email) => String.t() | nil
        }

  @doc "Builds the token response into the stored token shape."
  @spec from_response(map(), integer()) :: tokens()
  def from_response(%{} = resp, now_ms) do
    account = resp["account"] || %{}

    %{
      access: resp["access_token"],
      refresh: resp["refresh_token"],
      expires: now_ms + (resp["expires_in"] || 3600) * 1000,
      account_id: string_or_nil(account["uuid"]),
      email: string_or_nil(account["email_address"])
    }
  end

  @doc "True when the access token is missing or past its expiry."
  @spec expired?(tokens(), integer()) :: boolean()
  def expired?(%{access: access, expires: expires}, now_ms)
      when is_binary(access) and access != "" and is_integer(expires),
      do: expires <= now_ms

  def expired?(_tokens, _now_ms), do: true

  @doc "True when the credential can still serve a call (live, or refreshable)."
  @spec usable?(tokens(), integer()) :: boolean()
  def usable?(%{access: access} = tokens, now_ms) when is_binary(access) and access != "" do
    not expired?(tokens, now_ms) or
      match?(%{refresh: refresh} when is_binary(refresh) and refresh != "", tokens)
  end

  def usable?(_tokens, _now_ms), do: false

  @spec atomize(map()) :: tokens()
  def atomize(%{} = t) do
    %{
      access: t["access"],
      refresh: t["refresh"],
      expires: t["expires"] || 0,
      account_id: t["account_id"],
      email: t["email"]
    }
  end

  @spec stringify(tokens()) :: map()
  def stringify(%{} = t) do
    %{
      "access" => t.access,
      "refresh" => t.refresh,
      "expires" => t.expires,
      "account_id" => Map.get(t, :account_id),
      "email" => Map.get(t, :email)
    }
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
end
