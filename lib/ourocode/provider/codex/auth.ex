defmodule Ourocode.Provider.Codex.Auth do
  @moduledoc """
  Codex OAuth device authorization and access-token policy.
  """

  alias Ourocode.Provider.Codex.HTTP
  alias Ourocode.Provider.Codex.Store
  alias Ourocode.Provider.Codex.Token

  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"
  @issuer "https://auth.openai.com"
  @device_redirect "https://auth.openai.com/deviceauth/callback"
  @user_agent "ourocode/0.1.0"
  @originator "ourocode"

  @type tokens :: %{
          required(:access) => String.t(),
          required(:refresh) => String.t(),
          required(:expires) => integer(),
          optional(:account_id) => String.t() | nil,
          optional(:email) => String.t() | nil
        }

  @type device :: %{
          required(:device_auth_id) => String.t(),
          required(:user_code) => String.t(),
          required(:verification_uri) => String.t(),
          required(:interval_ms) => pos_integer()
        }

  @doc """
  Starts the headless device login. Returns the code the user must enter at
  `verification_uri` (no local listener involved).
  """
  @spec start_device_login() :: {:ok, device()} | {:error, term()}
  def start_device_login do
    HTTP.ensure_started()

    case HTTP.json(:post, "#{@issuer}/api/accounts/deviceauth/usercode", %{client_id: @client_id}) do
      {:ok, 200, %{"device_auth_id" => id, "user_code" => code} = body} ->
        interval = max(parse_int(body["interval"], 5), 1)

        {:ok,
         %{
           device_auth_id: id,
           user_code: code,
           verification_uri: "#{@issuer}/codex/device",
           interval_ms: interval * 1000 + 3000
         }}

      {:ok, status, body} ->
        {:error, {:device_init_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Polls once for the device-auth result.

  Returns `{:ok, tokens}` on success, `:pending` while the user has not yet
  approved, or `{:error, reason}` on a hard failure.
  """
  @spec poll_device_login(device()) :: {:ok, tokens()} | :pending | {:error, term()}
  def poll_device_login(%{device_auth_id: id, user_code: code}) do
    HTTP.ensure_started()

    case HTTP.json(:post, "#{@issuer}/api/accounts/deviceauth/token", %{
           device_auth_id: id,
           user_code: code
         }) do
      {:ok, 200, %{"authorization_code" => auth_code, "code_verifier" => verifier}} ->
        exchange_code(auth_code, verifier)

      {:ok, status, _body} when status in [403, 404] ->
        :pending

      {:ok, status, body} ->
        {:error, {:device_poll_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Refreshes and persists tokens using the stored refresh token."
  @spec refresh(tokens()) :: {:ok, tokens()} | {:error, term()}
  def refresh(%{refresh: refresh}) when is_binary(refresh) and refresh != "" do
    HTTP.ensure_started()

    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh,
      "client_id" => @client_id
    }

    case HTTP.form(:post, "#{@issuer}/oauth/token", form) do
      {:ok, 200, %{} = resp} ->
        merged =
          resp
          |> Token.from_response(now_ms())
          |> then(fn tokens ->
            if tokens.refresh in [nil, ""], do: %{tokens | refresh: refresh}, else: tokens
          end)

        :ok = Store.save(merged)
        {:ok, merged}

      {:ok, status, body} ->
        {:error, {:token_refresh_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def refresh(_tokens), do: {:error, :no_refresh_token}

  @doc """
  Returns a valid access token + account id for an API call, refreshing if the
  stored token has expired. `:error` when the user is not signed in.
  """
  @spec authorization() :: {:ok, %{access: String.t(), account_id: String.t() | nil}} | :error
  def authorization do
    with {:ok, tokens} <- Store.load() do
      case valid_authorization_tokens(tokens) do
        {:ok, tokens} ->
          {:ok, %{access: tokens.access, account_id: Map.get(tokens, :account_id)}}

        :error ->
          :error
      end
    else
      _ -> :error
    end
  end

  @doc "Request headers for the Codex Responses endpoint."
  @spec api_headers(String.t(), String.t() | nil, String.t()) :: [{String.t(), String.t()}]
  def api_headers(access, account_id, session_id) do
    [
      {"authorization", "Bearer " <> access},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"},
      {"originator", @originator},
      {"user-agent", @user_agent},
      {"session_id", session_id}
    ] ++ if(account_id, do: [{"ChatGPT-Account-Id", account_id}], else: [])
  end

  @doc false
  @spec issuer() :: String.t()
  def issuer, do: @issuer

  @doc false
  @spec client_id() :: String.t()
  def client_id, do: @client_id

  defp exchange_code(auth_code, verifier) do
    HTTP.ensure_started()

    form = %{
      "grant_type" => "authorization_code",
      "code" => auth_code,
      "redirect_uri" => @device_redirect,
      "client_id" => @client_id,
      "code_verifier" => verifier
    }

    case HTTP.form(:post, "#{@issuer}/oauth/token", form) do
      {:ok, 200, %{} = resp} ->
        tokens = Token.from_response(resp, now_ms())
        :ok = Store.save(tokens)
        {:ok, tokens}

      {:ok, status, body} ->
        {:error, {:token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_authorization_tokens(tokens) do
    tokens =
      if Token.expired?(tokens, now_ms()) do
        case refresh(tokens) do
          {:ok, refreshed} -> refreshed
          {:error, _reason} -> nil
        end
      else
        tokens
      end

    case tokens do
      %{access: access} = tokens when is_binary(access) and access != "" ->
        {:ok, tokens}

      _ ->
        :error
    end
  end

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp now_ms, do: System.system_time(:millisecond)
end
