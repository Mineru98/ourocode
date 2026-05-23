defmodule Ourocode.Terminal.InputEditor do
  @moduledoc """
  Pure prompt-buffer editing and kill-ring behavior for the terminal TUI.
  """

  @kill_ring_limit 10

  @spec edit_state(map(), map()) :: map()
  def edit_state(s, %{key: :ctrl_y}) do
    case List.first(s.kill_ring) do
      text when is_binary(text) and text != "" ->
        {buffer, cursor} = edit_input(s.buffer, s.cursor, %{key: :paste, char: text})

        %{
          s
          | buffer: buffer,
            cursor: cursor,
            kill_index: 0,
            last_yank: {s.cursor, String.length(text)}
        }

      _none ->
        s
    end
  end

  def edit_state(%{last_yank: {start, len}, kill_ring: ring} = s, %{key: :alt_y})
      when length(ring) > 1 do
    index = Integer.mod(s.kill_index + 1, length(ring))
    text = Enum.at(ring, index, "")
    graphemes = String.graphemes(s.buffer)
    {left, rest} = Enum.split(graphemes, start)
    {_old, right} = Enum.split(rest, len)
    insert = String.graphemes(text)
    buffer = Enum.join(left ++ insert ++ right)

    %{
      s
      | buffer: buffer,
        cursor: start + length(insert),
        kill_index: index,
        last_yank: {start, length(insert)}
    }
  end

  def edit_state(s, event) do
    killed = killed_text(s.buffer, s.cursor, event)
    {buffer, cursor} = edit_input(s.buffer, s.cursor, event)

    base =
      Map.merge(s, %{
        buffer: buffer,
        cursor: cursor,
        last_yank: nil,
        last_edit_was_kill: killed != "",
        esc_armed_until: nil,
        notifications: []
      })

    maybe_push_kill(base, killed, kill_direction(event), s.last_edit_was_kill)
  end

  @spec edit_input(String.t(), integer(), map()) :: {String.t(), integer()}
  def edit_input(buffer, cursor, event) when is_binary(buffer) and is_integer(cursor) do
    graphemes = String.graphemes(buffer)
    cursor = clamp_cursor(cursor, length(graphemes))

    {edited, cursor} =
      case event do
        %{key: :char, char: grapheme} when is_binary(grapheme) ->
          insert_text(graphemes, cursor, grapheme)

        %{key: :paste, char: text} when is_binary(text) ->
          insert_text(graphemes, cursor, normalize_paste(text))

        %{key: :backspace} ->
          delete_before(graphemes, cursor)

        %{key: :delete} ->
          delete_at(graphemes, cursor)

        %{key: :ctrl_d} ->
          delete_at(graphemes, cursor)

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
          delete_word_before(graphemes, cursor)

        %{key: :ctrl_y} ->
          {graphemes, cursor}

        %{key: :alt_b} ->
          {graphemes, word_before(graphemes, cursor)}

        %{key: :alt_f} ->
          {graphemes, word_after(graphemes, cursor)}

        %{key: :alt_d} ->
          delete_word_after(graphemes, cursor)

        %{key: :alt_y} ->
          {graphemes, cursor}

        _other ->
          {graphemes, cursor}
      end

    text = Enum.join(edited)
    {text, clamp_cursor(cursor, String.length(text))}
  end

  @spec clamp_cursor(integer(), non_neg_integer()) :: non_neg_integer()
  def clamp_cursor(cursor, len), do: cursor |> max(0) |> min(len)

  defp normalize_paste(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: true)
    |> Enum.map(&normalize_paste_line/1)
    |> Enum.join(" ")
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

  defp insert_text(graphemes, cursor, text) do
    insert = String.graphemes(text)
    {left, right} = Enum.split(graphemes, cursor)
    {left ++ insert ++ right, cursor + length(insert)}
  end

  defp delete_before(graphemes, 0), do: {graphemes, 0}

  defp delete_before(graphemes, cursor) do
    {left, right} = Enum.split(graphemes, cursor)
    {Enum.drop(left, -1) ++ right, cursor - 1}
  end

  defp delete_at(graphemes, cursor) do
    {left, right} = Enum.split(graphemes, cursor)
    {left ++ Enum.drop(right, 1), cursor}
  end

  defp delete_word_before(graphemes, cursor) do
    start = word_before(graphemes, cursor)
    {left, rest} = Enum.split(graphemes, start)
    {_deleted, right} = Enum.split(rest, cursor - start)
    {left ++ right, start}
  end

  defp delete_word_after(graphemes, cursor) do
    stop = word_after(graphemes, cursor)
    {left, rest} = Enum.split(graphemes, cursor)
    {_deleted, right} = Enum.split(rest, stop - cursor)
    {left ++ right, cursor}
  end

  defp word_before(graphemes, cursor) do
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

  defp word_after(graphemes, cursor) do
    tail = Enum.drop(graphemes, cursor)

    skipped =
      drop_while_index(tail, &blank?/1) +
        (tail
         |> Enum.drop(drop_while_index(tail, &blank?/1))
         |> drop_while_index(&(not blank?(&1))))

    min(cursor + skipped, length(graphemes))
  end

  defp drop_while_index(graphemes, pred) do
    Enum.reduce_while(graphemes, 0, fn g, idx ->
      if pred.(g), do: {:cont, idx + 1}, else: {:halt, idx}
    end)
  end

  defp blank?(grapheme), do: String.match?(grapheme, ~r/\s/u)

  defp killed_text(buffer, cursor, event) do
    graphemes = String.graphemes(buffer)
    cursor = clamp_cursor(cursor, length(graphemes))

    {from, to} =
      case event do
        %{key: :ctrl_u} ->
          {0, cursor}

        %{key: :cmd_backspace} ->
          {0, length(graphemes)}

        %{key: :ctrl_k} ->
          {cursor, length(graphemes)}

        %{key: key} when key in [:ctrl_w, :ctrl_backspace] ->
          {word_before(graphemes, cursor), cursor}

        %{key: :alt_d} ->
          {cursor, word_after(graphemes, cursor)}

        _other ->
          {0, 0}
      end

    if to > from do
      graphemes |> Enum.slice(from, to - from) |> Enum.join()
    else
      ""
    end
  end

  defp kill_direction(%{key: key})
       when key in [:ctrl_u, :ctrl_w, :ctrl_backspace, :cmd_backspace],
       do: :prepend

  defp kill_direction(_event), do: :append

  defp maybe_push_kill(s, "", _direction, _accumulating?), do: s

  defp maybe_push_kill(s, text, direction, accumulating?) do
    ring =
      case {s.kill_ring, direction, accumulating?} do
        {[], _direction, _accumulating?} -> [text]
        {ring, _direction, false} -> [text | ring]
        {[head | tail], :prepend, true} -> [text <> head | tail]
        {[head | tail], :append, true} -> [head <> text | tail]
      end
      |> Enum.take(@kill_ring_limit)

    %{s | kill_ring: ring, kill_index: 0}
  end
end
