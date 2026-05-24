defmodule Ourocode.MCP.Transport.SSE.Dispatch do
  @moduledoc """
  HTTP dispatch for JSON-RPC requests associated with an SSE connection.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.Http

  @spec request(map(), map(), pos_integer()) ::
          {:ok, integer(), map() | nil} | {:error, term()}
  def request(%{dispatch_uri: nil}, _request, _timeout), do: {:error, :missing_dispatch_url}

  def request(%{status: nil}, _request, _timeout), do: {:error, :sse_not_connected}

  def request(state, request, timeout) when is_map(request) do
    with :ok <- ensure_http_started(),
         {:ok, {{_, status, _reason}, _headers, body}} <-
           post_json(
             state.dispatch_uri,
             request,
             Map.get(state, :request_headers, []) || [],
             timeout
           ),
         {:ok, response} <- decode_response(status, body) do
      {:ok, status, response}
    end
  end

  @spec decode_response(integer(), binary() | charlist()) :: {:ok, map() | nil} | {:error, term()}
  def decode_response(status, body) when status in 200..299 do
    case String.trim(to_string(body)) do
      "" -> {:ok, nil}
      response_body -> Json.decode(response_body)
    end
  end

  def decode_response(status, body) do
    {:error, {:http_error, status, body}}
  end

  defp ensure_http_started do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:inets_start_failed, reason}}
    end
  end

  defp post_json(uri, request, headers, timeout) do
    body = request |> Json.encode!() |> IO.iodata_to_binary() |> String.to_charlist()

    request_headers =
      [
        {~c"accept", ~c"application/json, text/event-stream"}
      ] ++ charlist_headers_without(headers, ["content-type", "accept"])

    :httpc.request(
      :post,
      {uri |> URI.to_string() |> String.to_charlist(), request_headers, ~c"application/json",
       body},
      [timeout: timeout, connect_timeout: timeout],
      body_format: :binary
    )
  end

  defp charlist_headers_without(headers, excluded_keys) do
    headers
    |> Enum.reject(fn {key, _value} ->
      String.downcase(to_string(key)) in excluded_keys
    end)
    |> Http.charlist_headers()
  end
end
