defmodule Ourocode.Terminal.ScreenText do
  @moduledoc """
  Display-width helpers for terminal screen rendering.
  """

  @doc "Display columns a grapheme occupies (CJK/fullwidth = 2, else 1)."
  @spec char_width(String.t()) :: 1 | 2
  def char_width(grapheme) do
    case grapheme do
      <<cp::utf8, _::binary>> -> if wide?(cp), do: 2, else: 1
      _ -> 1
    end
  end

  @doc "Total display width of a string."
  @spec text_width(String.t()) :: non_neg_integer()
  def text_width(text) when is_binary(text) do
    text |> String.graphemes() |> Enum.reduce(0, &(&2 + char_width(&1)))
  end

  @doc "Truncates `text` to at most `max` display columns."
  @spec truncate(String.t(), integer()) :: String.t()
  def truncate(_text, max) when max <= 0, do: ""

  def truncate(text, max) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      w = char_width(g)
      if used + w > max, do: {:halt, {acc, used}}, else: {:cont, {[g | acc], used + w}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp wide?(cp) do
    (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0x303E) or
      (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x3400 and cp <= 0x4DBF) or
      (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xA000 and cp <= 0xA4CF) or
      (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
      (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
      (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1FAFF) or
      (cp >= 0x20000 and cp <= 0x3FFFD)
  end
end
