defmodule Ourocode.MCP.Transport.SSE.Connection do
  @moduledoc """
  TCP connection and HTTP request helpers for SSE transports.
  """

  alias Ourocode.MCP.Transport.Http

  @spec connect(URI.t(), pos_integer()) :: {:ok, port()} | {:error, term()}
  def connect(%URI{} = uri, timeout) when is_integer(timeout) and timeout > 0 do
    host = String.to_charlist(uri.host)
    port = uri.port || 80

    :gen_tcp.connect(host, port, [:binary, packet: :raw, active: false], timeout)
  end

  @spec send_request(port(), URI.t(), [{term(), term()}]) :: :ok | {:error, term()}
  def send_request(socket, %URI{} = uri, headers) when is_port(socket) and is_list(headers) do
    case :gen_tcp.send(socket, request(uri, headers)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:request_send_failed, reason}}
    end
  end

  @doc false
  @spec request(URI.t(), [{term(), term()}]) :: iodata()
  def request(%URI{} = uri, headers) when is_list(headers) do
    request_headers =
      [
        {"host", Http.host_header(uri)},
        {"accept", "text/event-stream"},
        {"cache-control", "no-cache"},
        {"connection", "keep-alive"}
      ] ++ headers

    [
      "GET ",
      Http.request_target(uri),
      " HTTP/1.1\r\n",
      Enum.map(request_headers, fn {key, value} ->
        [to_string(key), ": ", to_string(value), "\r\n"]
      end),
      "\r\n"
    ]
  end

  @doc false
  @spec parse_response_buffer(binary()) ::
          :partial
          | {:connected, integer(), list(), binary()}
          | {:http_error, integer(), list()}
          | {:error, term()}
  def parse_response_buffer(response_buffer) when is_binary(response_buffer) do
    case String.split(response_buffer, "\r\n\r\n", parts: 2) do
      [headers_blob, rest] ->
        parse_response_headers(headers_blob, rest)

      [_partial] ->
        :partial
    end
  end

  defp parse_response_headers(headers_blob, rest) do
    case Http.parse_response_headers(headers_blob) do
      {:ok, status, headers} when status in 200..299 ->
        if Http.event_stream?(headers) do
          {:connected, status, headers, rest}
        else
          {:error, :missing_event_stream_content_type}
        end

      {:ok, status, headers} ->
        {:http_error, status, headers}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
