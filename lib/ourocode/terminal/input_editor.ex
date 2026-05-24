defmodule Ourocode.Terminal.InputEditor do
  @moduledoc """
  Pure prompt-buffer editing and kill-ring behavior for the terminal TUI.
  """

  alias Ourocode.Terminal.{InputEditOperation, InputKillRing}

  @spec edit_state(map(), map()) :: map()
  def edit_state(s, %{key: :ctrl_y}) do
    InputKillRing.yank(s)
  end

  def edit_state(%{last_yank: {start, len}, kill_ring: ring} = s, %{key: :alt_y})
      when length(ring) > 1 do
    InputKillRing.rotate_yank(%{s | last_yank: {start, len}})
  end

  def edit_state(s, event) do
    killed = InputKillRing.killed_text(s.buffer, s.cursor, event)
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

    InputKillRing.push(base, killed, event, s.last_edit_was_kill)
  end

  @spec edit_input(String.t(), integer(), map()) :: {String.t(), integer()}
  def edit_input(buffer, cursor, event) when is_binary(buffer) and is_integer(cursor) do
    graphemes = String.graphemes(buffer)
    cursor = clamp_cursor(cursor, length(graphemes))

    {edited, cursor} = InputEditOperation.apply(graphemes, cursor, event)

    text = Enum.join(edited)
    {text, clamp_cursor(cursor, String.length(text))}
  end

  @spec clamp_cursor(integer(), non_neg_integer()) :: non_neg_integer()
  def clamp_cursor(cursor, len), do: cursor |> max(0) |> min(len)
end
