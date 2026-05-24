defmodule Ourocode.MCP.Transport.StreamableHTTP.Post do
  @moduledoc """
  Executes Streamable HTTP JSON-RPC POST requests.

  The transport first tries a raw TCP request so it can drain and emit SSE
  lifecycle frames incrementally. Non-SSE HTTP responses fall back to the
  `:httpc` request path used for ordinary JSON responses.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.Http
  alias Ourocode.MCP.Transport.StreamableHTTP.CallContext
  alias Ourocode.MCP.Transport.StreamableHTTP.Connection
  alias Ourocode.MCP.Transport.StreamableHTTP.SSEStream

  @spec json(String.t(), map(), keyword(), pos_integer(), (map() -> term())) ::
          {:ok, term()} | {:error, term()}
  def json(url, request, options, default_timeout, emit_fun)
      when is_binary(url) and is_map(request) and is_list(options) and
             is_integer(default_timeout) and default_timeout > 0 and is_function(emit_fun, 1) do
    case stream_json(url, request, options, default_timeout, emit_fun) do
      {:ok, result} ->
        {:ok, result}

      {:error, {:missing_event_stream_content_type, _status, _headers, _body}} ->
        httpc_json(url, request, options, default_timeout)

      {:error, {:unsupported_scheme, _scheme}} ->
        httpc_json(url, request, options, default_timeout)

      {:error, {:invalid_url, _url}} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp httpc_json(url, request, options, default_timeout) do
    Connection.httpc_post_json(url, request, options, default_timeout)
  end

  defp stream_json(url, request, options, default_timeout, emit_fun) do
    timeout = Keyword.get(options, :timeout, default_timeout)

    with {:ok, uri} <- Http.parse_http_url(url),
         {:ok, socket} <- Connection.connect(uri, timeout),
         :ok <- Connection.send_stream_request(socket, uri, request, options),
         {:ok, status, headers, body_rest} <-
           Connection.recv_response_headers(socket, "", timeout) do
      headers = Http.normalize_headers(headers)

      if Http.event_stream?(headers) do
        stream_sse_body(socket, status, headers, body_rest, options, request, timeout, emit_fun)
      else
        recv_json_body(socket, status, headers, body_rest, timeout)
      end
    end
  end

  defp recv_json_body(socket, status, headers, body_rest, timeout) do
    case Connection.recv_remaining_body(socket, headers, body_rest, timeout) do
      {:ok, body} ->
        :gen_tcp.close(socket)
        {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, headers, body}}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end

  defp stream_sse_body(socket, status, headers, body_rest, options, request, timeout, emit_fun) do
    context = CallContext.normalizer(options, request, Keyword.get(options, :event_seq, 1) + 1)

    case SSEStream.collect(
           socket,
           status,
           headers,
           body_rest,
           options,
           request,
           context,
           timeout,
           emit_fun
         ) do
      {:ok, response} ->
        :gen_tcp.close(socket)
        body = response |> Json.encode!() |> IO.iodata_to_binary()
        streamed_headers = [{"x-ourocode-streamed-sse", "true"} | headers]
        {:ok, {{~c"HTTP/1.1", status, ~c"OK"}, streamed_headers, body}}

      {:error, reason} ->
        :gen_tcp.close(socket)
        {:error, reason}
    end
  end
end
