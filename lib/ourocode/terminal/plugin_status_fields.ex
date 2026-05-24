defmodule Ourocode.Terminal.PluginStatusFields do
  @moduledoc """
  Shared field lookup and coercion helpers for plugin status projections.
  """

  @spec value(term(), atom(), term()) :: term()
  def value(map, key, default \\ nil)

  def value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  def value(_map, _key, default), do: default

  @spec text(term(), atom()) :: String.t() | nil
  def text(map, key) do
    case value(map, key) do
      nil -> nil
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  @spec boolean(term(), atom(), boolean()) :: boolean()
  def boolean(map, key, default) do
    case value(map, key) do
      value when is_boolean(value) -> value
      _value -> default
    end
  end
end
