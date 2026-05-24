defmodule Ourocode.WonderTool.DecisionRequest.Fields do
  @moduledoc """
  Field extraction helpers for mixed atom/string wonderTool payloads.
  """

  @spec first(map(), [term()]) :: term() | nil
  def first(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  @spec first_present(map(), [term()]) :: {term(), term()} | nil
  def first_present(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> {key, value}
        :error -> nil
      end
    end)
  end

  @spec map_field(map(), [term()]) :: map() | nil
  def map_field(map, keys) do
    case first(map, keys) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  @spec string_field(map(), [term()]) :: String.t() | nil
  def string_field(map, keys) do
    case first(map, keys) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  @spec put_present(map(), atom(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)
end
