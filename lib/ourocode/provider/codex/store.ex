defmodule Ourocode.Provider.Codex.Store do
  @moduledoc """
  Filesystem credential store for Codex OAuth tokens.

  The provider module owns OAuth flow orchestration. This module owns the local
  auth file path, serialization shape, file permissions, and sign-in state.
  """

  alias Ourocode.Json
  alias Ourocode.Provider.Codex.Token

  @type tokens :: Token.tokens()
  @key "codex"

  @doc "Absolute path of the credential file."
  @spec store_path() :: String.t()
  def store_path do
    Path.join([home_dir(), ".ourocode", "auth.json"])
  end

  @doc "Loads stored Codex tokens, or `:error` when not signed in."
  @spec load() :: {:ok, tokens()} | :error
  def load do
    with {:ok, body} <- File.read(store_path()),
         {:ok, %{@key => %{} = codex}} <- Json.decode(body) do
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

    existing =
      case File.read(path) do
        {:ok, body} ->
          case Json.decode(body),
            do: (
              {:ok, %{} = m} -> m
              _ -> %{}
            )

        _error ->
          %{}
      end

    payload = Map.put(existing, @key, Token.stringify(tokens))

    with :ok <- File.write(path, Json.encode!(payload)) do
      _ = File.chmod(path, 0o600)
      :ok
    end
  end

  @doc "Removes stored credentials (sign out)."
  @spec clear() :: :ok
  def clear do
    path = store_path()

    case File.read(path) do
      {:ok, body} ->
        case Json.decode(body) do
          {:ok, %{} = map} -> File.write(path, Json.encode!(Map.delete(map, @key)))
          _other -> :ok
        end

      _error ->
        :ok
    end

    :ok
  end

  @doc "True when the stored Codex credential can still serve a call."
  @spec signed_in?() :: boolean()
  def signed_in? do
    case load() do
      {:ok, tokens} -> Token.usable?(tokens, System.system_time(:millisecond))
      :error -> false
    end
  end

  defp home_dir do
    System.get_env("HOME") || System.user_home!() || System.tmp_dir!()
  end
end
