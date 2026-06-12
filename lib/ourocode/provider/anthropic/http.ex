defmodule Ourocode.Provider.Anthropic.HTTP do
  @moduledoc "Minimal HTTP boundary for Anthropic OAuth token requests."

  alias Ourocode.Json

  @spec ensure_started() :: :ok
  def ensure_started do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:inets)
    :ok
  end

  @spec json(:post, String.t(), map()) :: {:ok, non_neg_integer(), map()} | {:error, term()}
  def json(method, url, map) when is_map(map) do
    ensure_started()
    body = map |> Json.encode!() |> IO.iodata_to_binary()
    headers = [{~c"accept", ~c"application/json"}]
    request = {String.to_charlist(url), headers, ~c"application/json", body}

    case :httpc.request(method, request, [timeout: 30_000, connect_timeout: 15_000],
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
      _other -> %{"raw" => body}
    end
  end

  defp decode_body(_body), do: %{}
end
