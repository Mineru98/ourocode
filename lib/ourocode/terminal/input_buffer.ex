defmodule Ourocode.Terminal.InputBuffer do
  @moduledoc """
  Pure prompt-buffer editing primitives.
  """

  @spec normalize_paste(String.t()) :: String.t()
  def normalize_paste(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: true)
    |> Enum.map(&normalize_paste_line/1)
    |> Enum.join(" ")
  end

  @spec insert_text([String.t()], non_neg_integer(), String.t()) ::
          {[String.t()], non_neg_integer()}
  def insert_text(graphemes, cursor, text) when is_list(graphemes) and is_binary(text) do
    insert = String.graphemes(text)
    {left, right} = Enum.split(graphemes, cursor)
    {left ++ insert ++ right, cursor + length(insert)}
  end

  @spec delete_before([String.t()], non_neg_integer()) :: {[String.t()], non_neg_integer()}
  def delete_before(graphemes, 0), do: {graphemes, 0}

  def delete_before(graphemes, cursor) when is_list(graphemes) do
    {left, right} = Enum.split(graphemes, cursor)
    {Enum.drop(left, -1) ++ right, cursor - 1}
  end

  @spec delete_at([String.t()], non_neg_integer()) :: {[String.t()], non_neg_integer()}
  def delete_at(graphemes, cursor) when is_list(graphemes) do
    {left, right} = Enum.split(graphemes, cursor)
    {left ++ Enum.drop(right, 1), cursor}
  end

  @spec delete_word_before([String.t()], non_neg_integer()) :: {[String.t()], non_neg_integer()}
  def delete_word_before(graphemes, cursor) when is_list(graphemes) do
    start = word_before(graphemes, cursor)
    {left, rest} = Enum.split(graphemes, start)
    {_deleted, right} = Enum.split(rest, cursor - start)
    {left ++ right, start}
  end

  @spec delete_word_after([String.t()], non_neg_integer()) :: {[String.t()], non_neg_integer()}
  def delete_word_after(graphemes, cursor) when is_list(graphemes) do
    stop = word_after(graphemes, cursor)
    {left, rest} = Enum.split(graphemes, cursor)
    {_deleted, right} = Enum.split(rest, stop - cursor)
    {left ++ right, cursor}
  end

  @spec word_before([String.t()], non_neg_integer()) :: non_neg_integer()
  def word_before(graphemes, cursor) when is_list(graphemes) do
    reversed =
      graphemes
      |> Enum.take(cursor)
      |> Enum.reverse()

    blanks = drop_while_index(reversed, &blank?/1)

    word =
      reversed
      |> Enum.drop(blanks)
      |> drop_while_index(&(not blank?(&1)))

    max(cursor - blanks - word, 0)
  end

  @spec word_after([String.t()], non_neg_integer()) :: non_neg_integer()
  def word_after(graphemes, cursor) when is_list(graphemes) do
    tail = Enum.drop(graphemes, cursor)
    blanks = drop_while_index(tail, &blank?/1)

    skipped =
      blanks +
        (tail
         |> Enum.drop(blanks)
         |> drop_while_index(&(not blank?(&1))))

    min(cursor + skipped, length(graphemes))
  end

  defp normalize_paste_line("file://" <> uri) do
    path = URI.decode(uri)

    if image_path?(path) do
      "@image:" <> path
    else
      path
    end
  end

  defp normalize_paste_line(line), do: line

  defp image_path?(path) do
    path
    |> String.downcase()
    |> String.match?(~r/\.(png|jpe?g|gif|webp|heic|heif)$/)
  end

  defp drop_while_index(graphemes, pred) do
    Enum.reduce_while(graphemes, 0, fn g, idx ->
      if pred.(g), do: {:cont, idx + 1}, else: {:halt, idx}
    end)
  end

  defp blank?(grapheme), do: String.match?(grapheme, ~r/\s/u)
end
