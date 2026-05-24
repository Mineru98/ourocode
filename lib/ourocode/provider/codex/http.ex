defmodule Ourocode.Provider.Codex.HTTP do
  @moduledoc """
  Minimal HTTP boundary for Codex OAuth requests.
  """

  alias Ourocode.Json

  @user_agent "ourocode/0.1.0"

  @spec ensure_started() :: :ok
  def ensure_started do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    :ok
  end

  @spec json(:post, String.t(), map()) :: {:ok, non_neg_integer(), map()} | {:error, term()}
  def json(method, url, map) when is_map(map) do
    body = Json.encode!(map) |> IO.iodata_to_binary()
    request(method, url, ~c"application/json", body)
  end

  @spec form(:post, String.t(), map()) :: {:ok, non_neg_integer(), map()} | {:error, term()}
  def form(method, url, map) when is_map(map) do
    body = URI.encode_query(map)
    request(method, url, ~c"application/x-www-form-urlencoded", body)
  end

  @spec decode_body(term()) :: map()
  def decode_body(body) when is_binary(body) do
    case Json.decode(body) do
      {:ok, %{} = map} -> map
      _ -> %{"raw" => body}
    end
  end

  def decode_body(_body), do: %{}

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
end
