defmodule Ourocode.Terminal.FileMention do
  @moduledoc """
  Cursor-aware parsing and replacement for `@file` prompt mentions.
  """

  alias Ourocode.Terminal.InputEditor

  @spec active_query(String.t(), non_neg_integer()) :: String.t() | nil
  def active_query(prompt_buffer, cursor) when is_binary(prompt_buffer) do
    graphemes = String.graphemes(prompt_buffer)
    cursor = InputEditor.clamp_cursor(cursor, length(graphemes))
    prefix = graphemes |> Enum.take(cursor) |> Enum.join()

    case Regex.run(~r/(?:^|\s)@([^\s@]*)$/u, prefix) do
      [_, query] -> query
      _none -> nil
    end
  end

  @spec replace_active(String.t(), non_neg_integer(), String.t()) ::
          {String.t(), non_neg_integer()}
  def replace_active(buffer, cursor, path) do
    graphemes = String.graphemes(buffer)
    cursor = InputEditor.clamp_cursor(cursor, length(graphemes))
    {left, right} = Enum.split(graphemes, cursor)
    prefix = Enum.join(left)

    case Regex.run(~r/(^|\s)@([^\s@]*)$/u, prefix, return: :index) do
      [{start, _len}, {_sep_start, sep_len}, _query] ->
        before = binary_part(prefix, 0, start)
        sep = binary_part(prefix, start, sep_len)
        replacement = sep <> "@" <> path <> " "
        new_prefix = before <> replacement
        {new_prefix <> Enum.join(right), String.length(new_prefix)}

      _none ->
        text = "@" <> path <> " "
        {buffer <> text, String.length(buffer) + String.length(text)}
    end
  end

  @spec label(String.t()) :: String.t()
  def label(path) do
    path
    |> Path.dirname()
    |> case do
      "." -> "project file"
      dir -> dir
    end
  end
end
