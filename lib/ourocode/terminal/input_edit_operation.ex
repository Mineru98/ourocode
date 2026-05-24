defmodule Ourocode.Terminal.InputEditOperation do
  @moduledoc """
  Applies one prompt editing event to a grapheme buffer.
  """

  alias Ourocode.Terminal.InputBuffer

  @spec apply([String.t()], non_neg_integer(), map()) :: {[String.t()], non_neg_integer()}
  def apply(graphemes, cursor, event) when is_list(graphemes) and is_integer(cursor) do
    case event do
      %{key: :char, char: grapheme} when is_binary(grapheme) ->
        InputBuffer.insert_text(graphemes, cursor, grapheme)

      %{key: :paste, char: text} when is_binary(text) ->
        InputBuffer.insert_text(graphemes, cursor, InputBuffer.normalize_paste(text))

      %{key: :backspace} ->
        InputBuffer.delete_before(graphemes, cursor)

      %{key: key} when key in [:delete, :ctrl_d] ->
        InputBuffer.delete_at(graphemes, cursor)

      %{key: key} when key in [:left, :ctrl_b] ->
        {graphemes, max(cursor - 1, 0)}

      %{key: key} when key in [:right, :ctrl_f] ->
        {graphemes, min(cursor + 1, length(graphemes))}

      %{key: key} when key in [:home, :ctrl_a] ->
        {graphemes, 0}

      %{key: key} when key in [:end, :ctrl_e] ->
        {graphemes, length(graphemes)}

      %{key: :ctrl_u} ->
        {Enum.drop(graphemes, cursor), 0}

      %{key: :ctrl_k} ->
        {Enum.take(graphemes, cursor), cursor}

      %{key: :cmd_backspace} ->
        {[], 0}

      %{key: key} when key in [:ctrl_backspace, :ctrl_w] ->
        InputBuffer.delete_word_before(graphemes, cursor)

      %{key: key} when key in [:ctrl_y, :alt_y] ->
        {graphemes, cursor}

      %{key: :alt_b} ->
        {graphemes, InputBuffer.word_before(graphemes, cursor)}

      %{key: :alt_f} ->
        {graphemes, InputBuffer.word_after(graphemes, cursor)}

      %{key: :alt_d} ->
        InputBuffer.delete_word_after(graphemes, cursor)

      _other ->
        {graphemes, cursor}
    end
  end
end
