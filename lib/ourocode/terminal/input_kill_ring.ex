defmodule Ourocode.Terminal.InputKillRing do
  @moduledoc """
  Kill-ring capture and yank behavior for prompt editing.
  """

  alias Ourocode.Terminal.InputBuffer

  @limit 10

  @spec yank(map()) :: map()
  def yank(state) do
    case List.first(state.kill_ring) do
      text when is_binary(text) and text != "" ->
        graphemes = String.graphemes(state.buffer)
        {edited, cursor} = InputBuffer.insert_text(graphemes, state.cursor, text)

        %{
          state
          | buffer: Enum.join(edited),
            cursor: cursor,
            kill_index: 0,
            last_yank: {state.cursor, String.length(text)}
        }

      _none ->
        state
    end
  end

  @spec rotate_yank(map()) :: map()
  def rotate_yank(%{last_yank: {start, len}, kill_ring: ring} = state) when length(ring) > 1 do
    index = Integer.mod(state.kill_index + 1, length(ring))
    text = Enum.at(ring, index, "")
    graphemes = String.graphemes(state.buffer)
    {left, rest} = Enum.split(graphemes, start)
    {_old, right} = Enum.split(rest, len)
    insert = String.graphemes(text)
    buffer = Enum.join(left ++ insert ++ right)

    %{
      state
      | buffer: buffer,
        cursor: start + length(insert),
        kill_index: index,
        last_yank: {start, length(insert)}
    }
  end

  @spec killed_text(String.t(), integer(), map()) :: String.t()
  def killed_text(buffer, cursor, event) do
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
          {InputBuffer.word_before(graphemes, cursor), cursor}

        %{key: :alt_d} ->
          {cursor, InputBuffer.word_after(graphemes, cursor)}

        _other ->
          {0, 0}
      end

    if to > from do
      graphemes |> Enum.slice(from, to - from) |> Enum.join()
    else
      ""
    end
  end

  @spec push(map(), String.t(), map(), boolean()) :: map()
  def push(state, "", _event, _accumulating?), do: state

  def push(state, text, event, accumulating?) do
    ring =
      case {state.kill_ring, direction(event), accumulating?} do
        {[], _direction, _accumulating?} -> [text]
        {ring, _direction, false} -> [text | ring]
        {[head | tail], :prepend, true} -> [text <> head | tail]
        {[head | tail], :append, true} -> [head <> text | tail]
      end
      |> Enum.take(@limit)

    %{state | kill_ring: ring, kill_index: 0}
  end

  defp direction(%{key: key}) when key in [:ctrl_u, :ctrl_w, :ctrl_backspace, :cmd_backspace],
    do: :prepend

  defp direction(_event), do: :append

  defp clamp_cursor(cursor, len), do: cursor |> max(0) |> min(len)
end
