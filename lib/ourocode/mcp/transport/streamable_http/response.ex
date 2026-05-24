defmodule Ourocode.MCP.Transport.StreamableHTTP.Response do
  @moduledoc """
  Decodes Streamable HTTP JSON and SSE response bodies.
  """

  alias Ourocode.Json
  alias Ourocode.MCP.Transport.Http
  alias Ourocode.MCP.Transport.StreamableHTTP.LifecycleNormalizer

  @spec decode(non_neg_integer(), [{term(), term()}], binary()) :: {:ok, map()} | {:error, term()}
  def decode(status, headers, body) when status in 200..299 do
    cond do
      streamed_sse?(headers) ->
        Json.decode(body)

      Http.event_stream?(headers) ->
        with {:ok, events} <- LifecycleNormalizer.parse_sse(body) do
          {:ok, from_sse_events(events)}
        end

      true ->
        Json.decode(body)
    end
  end

  def decode(status, _headers, body) do
    {:error, {:http_error, status, body}}
  end

  @spec from_sse_events([map()]) :: map()
  def from_sse_events(events) when is_list(events) do
    events
    |> response_from_json_rpc_event()
    |> case do
      nil -> %{"events" => Enum.map(events, &Map.fetch!(&1, "data"))}
      response -> response
    end
  end

  @spec from_parsed_events([map()]) :: map() | nil
  def from_parsed_events(events) when is_list(events) do
    response_from_json_rpc_event(events)
  end

  @spec content_length([{term(), term()}]) :: non_neg_integer() | nil
  def content_length(headers) when is_list(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == "content-length" do
        case Integer.parse(to_string(value)) do
          {length, ""} -> length
          _ -> nil
        end
      end
    end)
  end

  @spec streamed_sse?([{term(), term()}]) :: boolean()
  def streamed_sse?(headers) when is_list(headers) do
    Enum.any?(headers, fn {key, value} ->
      String.downcase(to_string(key)) == "x-ourocode-streamed-sse" and
        String.downcase(to_string(value)) == "true"
    end)
  end

  defp response_from_json_rpc_event(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"data" => %{"id" => _id} = data} -> data
      _event -> nil
    end)
  end
end
