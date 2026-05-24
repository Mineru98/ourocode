defmodule Ourocode.MCP.Transport.Http do
  @moduledoc """
  Shared pure HTTP helpers used by MCP transports.
  """

  @spec parse_http_url(String.t()) :: {:ok, URI.t()} | {:error, term()}
  def parse_http_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "http" -> {:error, {:unsupported_scheme, uri.scheme}}
      is_nil(uri.host) -> {:error, {:invalid_url, url}}
      true -> {:ok, uri}
    end
  end

  @spec parse_optional_http_url!(String.t() | nil, String.t()) :: URI.t() | nil
  def parse_optional_http_url!(nil, _label), do: nil

  def parse_optional_http_url!(url, label) when is_binary(url) do
    case parse_http_url(url) do
      {:ok, uri} -> uri
      {:error, reason} -> raise ArgumentError, "invalid #{label}: #{inspect(reason)}"
    end
  end

  @spec host_header(URI.t()) :: String.t()
  def host_header(%URI{} = uri) do
    if uri.port && uri.port != 80 do
      "#{uri.host}:#{uri.port}"
    else
      uri.host
    end
  end

  @spec request_target(URI.t()) :: String.t()
  def request_target(%URI{} = uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    case uri.query do
      nil -> path
      "" -> path
      query -> path <> "?" <> query
    end
  end

  @spec parse_response_headers(String.t()) ::
          {:ok, non_neg_integer(), [{String.t(), String.t()}]} | {:error, term()}
  def parse_response_headers(headers_blob) when is_binary(headers_blob) do
    [status_line | header_lines] = String.split(headers_blob, "\r\n")

    with [_, status_text | _] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(status_text) do
      headers =
        Enum.flat_map(header_lines, fn line ->
          case String.split(line, ":", parts: 2) do
            [key, value] -> [{String.downcase(key), String.trim_leading(value)}]
            _line -> []
          end
        end)

      {:ok, status, headers}
    else
      _invalid -> {:error, {:invalid_response_headers, headers_blob}}
    end
  end

  @spec normalize_headers([{term(), term()}]) :: [{String.t(), String.t()}]
  def normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  @spec charlist_headers([{term(), term()}]) :: [{charlist(), charlist()}]
  def charlist_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  @spec event_stream?([{term(), term()}]) :: boolean()
  def event_stream?(headers) when is_list(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(to_string(key)) == "content-type" and
        value |> to_string() |> String.downcase() |> String.contains?("text/event-stream")
    end)
  end
end
