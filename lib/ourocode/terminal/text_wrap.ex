defmodule Ourocode.Terminal.TextWrap do
  @moduledoc """
  Width-aware text wrapping for terminal rendering.
  """

  alias Ourocode.Terminal.Screen

  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    {lines, cur} =
      text
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reduce({[], ""}, fn word, {lines, cur} ->
        cond do
          Screen.text_width(word) > width ->
            [head | tail] = hard_split(word, width)
            flushed = if cur == "", do: lines, else: [cur | lines]
            stack = Enum.reduce(Enum.drop(tail, -1), [head | flushed], &[&1 | &2])
            {stack, List.last(tail) || head}

          cur == "" ->
            {lines, word}

          Screen.text_width(cur) + 1 + Screen.text_width(word) <= width ->
            {lines, cur <> " " <> word}

          true ->
            {[cur | lines], word}
        end
      end)

    case Enum.reverse([cur | lines]) |> Enum.reject(&(&1 == "")) do
      [] -> [""]
      wrapped -> wrapped
    end
  end

  def wrap(text, _width) when is_binary(text), do: [text]
  def wrap(_text, _width), do: [""]

  defp hard_split("", _width), do: []

  defp hard_split(word, width) do
    # Ensure progress when the first grapheme is wider than the target width.
    chunk =
      case Screen.truncate(word, width) do
        "" -> String.first(word)
        c -> c
      end

    case String.replace_prefix(word, chunk, "") do
      "" -> [chunk]
      rest -> [chunk | hard_split(rest, width)]
    end
  end
end
