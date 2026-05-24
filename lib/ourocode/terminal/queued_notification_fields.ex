defmodule Ourocode.Terminal.QueuedNotificationFields do
  @moduledoc """
  Shared field lookup and terminal-safe text coercion for queued notifications.
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
      value when is_binary(value) -> terminal_safe(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  @spec terminal_safe(String.t()) :: String.t()
  def terminal_safe(text) when is_binary(text) do
    text
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.trim()
  end
end
