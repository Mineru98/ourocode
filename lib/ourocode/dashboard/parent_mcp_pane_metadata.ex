defmodule Ourocode.Dashboard.ParentMcpPaneMetadata do
  @moduledoc """
  Normalizes metadata and update payload values for parent MCP panes.
  """

  @valid_statuses [:starting, :streaming, :completed, :failed]
  @valid_transports [:stdio, :streamable_http, :sse]

  @spec value(map(), atom()) :: term()
  def value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  @spec string(map(), atom()) :: {:ok, String.t()} | :error
  def string(metadata, key) when is_map(metadata) and is_atom(key) do
    case value(metadata, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      value when is_integer(value) -> {:ok, Integer.to_string(value)}
      value when is_atom(value) and not is_nil(value) -> {:ok, Atom.to_string(value)}
      _value -> :error
    end
  end

  @spec string_or_nil(map(), atom()) :: String.t() | nil
  def string_or_nil(metadata, key) when is_map(metadata) and is_atom(key) do
    case string(metadata, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @spec transport(map()) :: {:ok, atom()} | :error
  def transport(metadata) when is_map(metadata) do
    case value(metadata, :transport) do
      transport when transport in @valid_transports -> {:ok, transport}
      "stdio" -> {:ok, :stdio}
      "streamable_http" -> {:ok, :streamable_http}
      "sse" -> {:ok, :sse}
      _transport -> :error
    end
  end

  @spec integer(map(), atom()) :: integer() | nil
  def integer(metadata, key) when is_map(metadata) and is_atom(key) do
    metadata
    |> value(key)
    |> normalize_integer()
  end

  @spec map_value(map(), atom(), map()) :: map()
  def map_value(metadata, key, default)
      when is_map(metadata) and is_atom(key) and is_map(default) do
    case value(metadata, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  @spec normalize_status(term()) :: atom() | nil
  def normalize_status(status) when status in @valid_statuses, do: status
  def normalize_status("starting"), do: :starting
  def normalize_status("streaming"), do: :streaming
  def normalize_status("completed"), do: :completed
  def normalize_status("failed"), do: :failed
  def normalize_status(_status), do: nil

  @spec normalize_transport(term()) :: atom() | nil
  def normalize_transport(transport) when transport in @valid_transports, do: transport
  def normalize_transport("stdio"), do: :stdio
  def normalize_transport("streamable_http"), do: :streamable_http
  def normalize_transport("sse"), do: :sse
  def normalize_transport(_transport), do: nil

  @spec normalize_string(term()) :: String.t() | nil
  def normalize_string(value) when is_binary(value) and value != "", do: value
  def normalize_string(value) when is_integer(value), do: Integer.to_string(value)
  def normalize_string(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  def normalize_string(_value), do: nil

  @spec normalize_optional_string(term()) :: String.t() | nil
  def normalize_optional_string(nil), do: nil
  def normalize_optional_string(value), do: normalize_string(value)

  @spec normalize_integer(term()) :: integer() | nil
  def normalize_integer(value) when is_integer(value), do: value

  def normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  def normalize_integer(_value), do: nil
end
