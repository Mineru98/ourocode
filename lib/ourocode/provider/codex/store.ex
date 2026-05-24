defmodule Ourocode.Provider.Codex.Store do
  @moduledoc """
  Filesystem credential store for Codex OAuth tokens.

  The provider module owns OAuth flow orchestration. This module owns the local
  auth file path, serialization shape, file permissions, and sign-in state.
  """

  alias Ourocode.Json
  alias Ourocode.Provider.Codex.Token

  @type tokens :: Token.tokens()

  @doc "Absolute path of the credential file."
  @spec store_path() :: String.t()
  def store_path do
    Path.join([home_dir(), ".ourocode", "auth.json"])
  end

  @doc "Loads stored Codex tokens, or `:error` when not signed in."
  @spec load() :: {:ok, tokens()} | :error
  def load do
    with {:ok, body} <- File.read(store_path()),
         {:ok, %{"codex" => %{} = codex}} <- Json.decode(body) do
      {:ok, Token.atomize(codex)}
    else
      _not_signed_in -> :error
    end
  end

  @doc "Persists Codex tokens to the credential file (0600)."
  @spec save(tokens()) :: :ok | {:error, term()}
  def save(%{} = tokens) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))
    payload = %{"codex" => Token.stringify(tokens)}

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
    match?({:ok, %{access: access}} when is_binary(access) and access != "", load())
  end

  defp home_dir do
    System.get_env("HOME") || System.user_home!() || System.tmp_dir!()
  end
end
