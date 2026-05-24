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

  alias Ourocode.Provider.Codex.Auth
  alias Ourocode.Provider.Codex.Store
  alias Ourocode.Provider.Codex.Token

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
  defdelegate store_path, to: Store

  @doc "Loads stored Codex tokens, or `:error` when not signed in."
  @spec load() :: {:ok, tokens()} | :error
  defdelegate load, to: Store

  @doc "Persists Codex tokens to the credential file (0600)."
  @spec save(tokens()) :: :ok | {:error, term()}
  defdelegate save(tokens), to: Store

  @doc "Removes stored credentials (sign out)."
  @spec clear() :: :ok
  defdelegate clear, to: Store

  @doc "True when a credential file with a Codex access token exists."
  @spec signed_in?() :: boolean()
  defdelegate signed_in?, to: Store

  # --- pure helpers (unit tested) -----------------------------------------

  @doc "Decodes the JWT payload claims, or `nil` for a malformed token."
  @spec parse_jwt_claims(String.t() | nil) :: map() | nil
  defdelegate parse_jwt_claims(token), to: Token

  @doc "Extracts the ChatGPT account id from JWT claims with opencode precedence."
  @spec extract_account_id_from_claims(map()) :: String.t() | nil
  defdelegate extract_account_id_from_claims(claims), to: Token

  @doc "Resolves the account id from a token response (id_token then access_token)."
  @spec extract_account_id(map()) :: String.t() | nil
  defdelegate extract_account_id(token_response), to: Token

  @doc "Email claim from the id_token, if present."
  @spec extract_email(map()) :: String.t() | nil
  defdelegate extract_email(token_response), to: Token

  @doc "Builds the token response into the stored token shape."
  @spec tokens_from_response(map(), integer()) :: tokens()
  defdelegate tokens_from_response(resp, now_ms), to: Token, as: :from_response

  @doc "True when the access token is missing or past its expiry."
  @spec expired?(tokens(), integer()) :: boolean()
  defdelegate expired?(tokens, now_ms), to: Token

  # --- device authorization grant -----------------------------------------

  @doc """
  Starts the headless device login. Returns the code the user must enter at
  `verification_uri` (no local listener involved).
  """
  @spec start_device_login() :: {:ok, device()} | {:error, term()}
  defdelegate start_device_login(), to: Auth

  @doc """
  Polls once for the device-auth result.

  Returns `{:ok, tokens}` on success, `:pending` while the user has not yet
  approved, or `{:error, reason}` on a hard failure.
  """
  @spec poll_device_login(device()) :: {:ok, tokens()} | :pending | {:error, term()}
  defdelegate poll_device_login(device), to: Auth

  @doc "Refreshes and persists tokens using the stored refresh token."
  @spec refresh(tokens()) :: {:ok, tokens()} | {:error, term()}
  defdelegate refresh(tokens), to: Auth

  @doc """
  Returns a valid access token + account id for an API call, refreshing if the
  stored token has expired. `:error` when the user is not signed in.
  """
  @spec authorization() :: {:ok, %{access: String.t(), account_id: String.t() | nil}} | :error
  defdelegate authorization(), to: Auth

  @doc "Request headers for the Codex Responses endpoint."
  @spec api_headers(String.t(), String.t() | nil, String.t()) :: [{String.t(), String.t()}]
  defdelegate api_headers(access, account_id, session_id), to: Auth

  defdelegate issuer(), to: Auth
  defdelegate client_id(), to: Auth
end
