defmodule Ourocode.Terminal.CommandSuggestions do
  @moduledoc """
  Suggests nearby slash commands for mistyped terminal input.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry

  @spec unknown_reason(String.t(), map()) :: {:unknown_command, String.t(), [String.t()]}
  def unknown_reason(command, registry) when is_binary(command) and is_map(registry) do
    {:unknown_command, command, suggestions(registry, command)}
  end

  @spec suggestions(map(), String.t()) :: [String.t()]
  def suggestions(registry, command) when is_map(registry) and is_binary(command) do
    needle = normalize_token(command)

    registry
    |> CommandRegistry.entries()
    |> Enum.flat_map(fn entry ->
      [entry.slash | Map.get(entry, :aliases, [])]
      |> Enum.map(fn token ->
        {entry.slash, token, edit_distance(needle, normalize_token(token))}
      end)
    end)
    |> Enum.sort_by(fn {_slash, token, distance} -> {distance, String.length(token), token} end)
    |> Enum.reduce([], fn {slash, _token, distance}, acc ->
      if slash in acc or distance > max(3, div(String.length(needle), 2)),
        do: acc,
        else: acc ++ [slash]
    end)
    |> Enum.take(3)
  end

  def suggestions(_registry, _command), do: []

  @spec edit_distance(String.t(), String.t()) :: non_neg_integer()
  def edit_distance(a, b) when is_binary(a) and is_binary(b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)
    previous = Enum.to_list(0..length(b_chars))

    a_chars
    |> Enum.with_index(1)
    |> Enum.reduce(previous, fn {a_char, i}, prev ->
      {_left, row} =
        b_chars
        |> Enum.with_index(1)
        |> Enum.reduce({i, [i]}, fn {b_char, j}, {left, row} ->
          insert = left + 1
          delete = Enum.at(prev, j) + 1
          replace = Enum.at(prev, j - 1) + if(a_char == b_char, do: 0, else: 1)
          value = min(insert, min(delete, replace))
          {value, [value | row]}
        end)

      Enum.reverse(row)
    end)
    |> List.last()
  end

  defp normalize_token(token) do
    token
    |> to_string()
    |> String.trim()
    |> String.trim_leading("/")
    |> String.downcase()
  end
end
