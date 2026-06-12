defmodule Ourocode.Provider.Anthropic.Store do
  @moduledoc """
  Filesystem credential store for Anthropic OAuth tokens.

  Shares `~/.ourocode/auth.json` with the Codex store but owns the
  `"anthropic"` key, so the two providers persist side by side.
  """

  alias Ourocode.Json
  alias Ourocode.Provider.Anthropic.Token

  @type tokens :: Token.tokens()

  @key "anthropic"

  @spec store_path() :: String.t()
  def store_path, do: Path.join([home_dir(), ".ourocode", "auth.json"])

  @spec load() :: {:ok, tokens()} | :error
  def load do
    with {:ok, body} <- File.read(store_path()),
         {:ok, %{@key => %{} = creds}} <- Json.decode(body) do
      {:ok, Token.atomize(creds)}
    else
      _not_signed_in -> :error
    end
  end

  @spec save(tokens()) :: :ok | {:error, term()}
  def save(%{} = tokens) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))

    # Preserve other providers' credentials in the shared file.
    existing =
      case File.read(path) do
        {:ok, body} -> case Json.decode(body), do: ({:ok, %{} = m} -> m; _ -> %{})
        _error -> %{}
      end

    payload = Map.put(existing, @key, Token.stringify(tokens))

    with :ok <- File.write(path, Json.encode!(payload)) do
      _ = File.chmod(path, 0o600)
      :ok
    end
  end

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

  @spec signed_in?() :: boolean()
  def signed_in? do
    case load() do
      {:ok, tokens} -> Token.usable?(tokens, System.system_time(:millisecond))
      :error -> false
    end
  end

  defp home_dir, do: System.get_env("HOME") || System.user_home!() || System.tmp_dir!()
end
