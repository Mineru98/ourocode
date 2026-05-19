defmodule Ourocode.MCP.Transport.RawProtocolMessage do
  @moduledoc """
  Typed raw JSON-RPC protocol message decoded from an MCP transport stream.

  The struct keeps the original decoded object intact for downstream
  normalization while giving transports a stable, transport-neutral message
  kind to route on before journaling.
  """

  @type kind :: :request | :notification | :response | :error_response | :unknown
  @type id :: String.t() | integer() | nil

  @type t :: %__MODULE__{
          kind: kind(),
          raw: map(),
          jsonrpc: String.t() | nil,
          id: id(),
          method: String.t() | nil,
          params: map() | list() | nil,
          result: term(),
          error: term(),
          line: String.t() | nil
        }

  defstruct [
    :kind,
    :raw,
    :jsonrpc,
    :id,
    :method,
    :params,
    :result,
    :error,
    :line
  ]

  @doc """
  Builds a typed raw protocol message from a decoded JSON object.
  """
  @spec from_decoded(map(), String.t() | nil) :: t()
  def from_decoded(decoded, line \\ nil) when is_map(decoded) do
    %__MODULE__{
      kind: classify(decoded),
      raw: decoded,
      jsonrpc: string_or_nil(Map.get(decoded, "jsonrpc")),
      id: Map.get(decoded, "id"),
      method: string_or_nil(Map.get(decoded, "method")),
      params: Map.get(decoded, "params"),
      result: Map.get(decoded, "result"),
      error: Map.get(decoded, "error"),
      line: line
    }
  end

  defp classify(%{"method" => method} = decoded) when is_binary(method) do
    if Map.has_key?(decoded, "id"), do: :request, else: :notification
  end

  defp classify(%{"error" => _error} = decoded) do
    if Map.has_key?(decoded, "id"), do: :error_response, else: :unknown
  end

  defp classify(%{"result" => _result} = decoded) do
    if Map.has_key?(decoded, "id"), do: :response, else: :unknown
  end

  defp classify(_decoded), do: :unknown

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil
end
