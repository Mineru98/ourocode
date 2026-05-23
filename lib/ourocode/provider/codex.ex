defmodule Ourocode.Provider.Codex do
  @moduledoc """
  ChatGPT (Codex) OAuth + token store for the main-session LLM.

  ourocode itself hosts no model. This connects the main session to the user's
  ChatGPT Plus/Pro plan through the shared Codex OAuth client used by compatible
  CLI implementations. Only the headless device-authorization grant is implemented so
  the terminal baseline never needs a local web server / redirect listener,
  staying inside the seed's "must not require a local web server" boundary.

  The pure pieces (JWT claim parsing, account-id extraction, request building,
  token-store (de)serialization, expiry) are isolated and unit-tested; the
  network steps follow the Codex device-authorization protocol.
  """

  alias Ourocode.Json

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

  # --- token store ---------------------------------------------------------

  @doc "Absolute path of the credential file."
  @spec store_path() :: String.t()
  def store_path do
    Path.join([System.user_home!() || System.tmp_dir!(), ".ourocode", "auth.json"])
  end

  @doc "Loads stored Codex tokens, or `:error` when not signed in."
  @spec load() :: {:ok, tokens()} | :error
  def load do
    with {:ok, body} <- File.read(store_path()),
         {:ok, %{"codex" => %{} = codex}} <- Json.decode(body) do
      {:ok, atomize_tokens(codex)}
    else
      _not_signed_in -> :error
    end
  end

  @doc "Persists Codex tokens to the credential file (0600)."
  @spec save(tokens()) :: :ok | {:error, term()}
  def save(%{} = tokens) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))
    payload = %{"codex" => stringify_tokens(tokens)}

    with :ok <- File.write(path, Json.encode!(payload)) do
      _ = File.chmod(path, 0o600)
      :ok
    end
  end

  @doc "Removes stored credentials (sign out)."
  @spec clear() :: :ok
  def clear do
    _ = File.rm(store_path())
    :ok
  end

  @doc "True when a credential file with a Codex access token exists."
  @spec signed_in?() :: boolean()
  def signed_in? do
    match?({:ok, %{access: a}} when is_binary(a) and a != "", load())
  end

  # --- pure helpers (unit tested) -----------------------------------------

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

  defp from(token) do
    case parse_jwt_claims(token) do
      %{} = claims -> extract_account_id_from_claims(claims)
      _ -> nil
    end
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
  @spec tokens_from_response(map(), integer()) :: tokens()
  def tokens_from_response(%{} = resp, now_ms) do
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

  # --- device authorization grant -----------------------------------------

  @doc """
  Starts the headless device login. Returns the code the user must enter at
  `verification_uri` (no local listener involved).
  """
  @spec start_device_login() :: {:ok, device()} | {:error, term()}
  def start_device_login do
    ensure_http()

    case http_json(:post, "#{@issuer}/api/accounts/deviceauth/usercode", %{client_id: @client_id}) do
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
    ensure_http()

    case http_json(:post, "#{@issuer}/api/accounts/deviceauth/token", %{
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

  defp exchange_code(auth_code, verifier) do
    ensure_http()

    form = %{
      "grant_type" => "authorization_code",
      "code" => auth_code,
      "redirect_uri" => @device_redirect,
      "client_id" => @client_id,
      "code_verifier" => verifier
    }

    case http_form(:post, "#{@issuer}/oauth/token", form) do
      {:ok, 200, %{} = resp} ->
        tokens = tokens_from_response(resp, now_ms())
        :ok = save(tokens)
        {:ok, tokens}

      {:ok, status, body} ->
        {:error, {:token_exchange_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Refreshes and persists tokens using the stored refresh token."
  @spec refresh(tokens()) :: {:ok, tokens()} | {:error, term()}
  def refresh(%{refresh: refresh}) when is_binary(refresh) and refresh != "" do
    ensure_http()

    form = %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh,
      "client_id" => @client_id
    }

    case http_form(:post, "#{@issuer}/oauth/token", form) do
      {:ok, 200, %{} = resp} ->
        merged =
          resp
          |> tokens_from_response(now_ms())
          |> then(fn t -> if t.refresh in [nil, ""], do: %{t | refresh: refresh}, else: t end)

        :ok = save(merged)
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
    with {:ok, tokens} <- load() do
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

  defp valid_authorization_tokens(tokens) do
    tokens =
      if expired?(tokens, now_ms()) do
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

  def issuer, do: @issuer
  def client_id, do: @client_id

  # --- internals -----------------------------------------------------------

  defp atomize_tokens(%{} = m) do
    %{
      access: m["access"],
      refresh: m["refresh"],
      expires: m["expires"] || 0,
      account_id: m["account_id"],
      email: m["email"]
    }
  end

  defp stringify_tokens(%{} = t) do
    %{
      "access" => t.access,
      "refresh" => t.refresh,
      "expires" => t.expires,
      "account_id" => Map.get(t, :account_id),
      "email" => Map.get(t, :email)
    }
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

  defp parse_int(value, _default) when is_integer(value), do: value

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp now_ms, do: System.system_time(:millisecond)

  defp ensure_http do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    :ok
  end

  defp http_json(method, url, map) do
    body = Json.encode!(map) |> IO.iodata_to_binary()
    request(method, url, ~c"application/json", body)
  end

  defp http_form(method, url, map) do
    body = URI.encode_query(map)
    request(method, url, ~c"application/x-www-form-urlencoded", body)
  end

  defp request(method, url, content_type, body) do
    headers = [{~c"user-agent", String.to_charlist(@user_agent)}]

    http_request =
      {String.to_charlist(url), headers, content_type, body}

    case :httpc.request(method, http_request, [timeout: 30_000, connect_timeout: 15_000],
           body_format: :binary
         ) do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, decode_body(resp_body)}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp decode_body(body) when is_binary(body) do
    case Json.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{"raw" => body}
    end
  end

  defp decode_body(_body), do: %{}
end
