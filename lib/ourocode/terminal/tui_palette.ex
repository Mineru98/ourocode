defmodule Ourocode.Terminal.TuiPalette do
  @moduledoc """
  Handles slash-command palette mode key events.
  """

  alias Ourocode.Terminal.{Palette, TuiState}

  @edit_keys [
    :delete,
    :left,
    :right,
    :home,
    :end,
    :ctrl_a,
    :ctrl_b,
    :ctrl_d,
    :ctrl_e,
    :ctrl_f,
    :ctrl_k,
    :ctrl_u,
    :ctrl_w,
    :ctrl_y,
    :alt_b,
    :alt_d,
    :alt_f,
    :alt_y,
    :cmd_backspace,
    :ctrl_backspace
  ]

  @spec handle_event(map(), pid(), (String.t() -> term()), (-> term()), (-> term())) :: term()
  def handle_event(event, state, submit, draw, cont) do
    case event do
      %{key: :escape} ->
        close(state)
        draw.()
        cont.()

      %{key: down} when down in [:down, :tab] ->
        TuiState.put_pidx(state, TuiState.pidx(state) + 1)
        draw.()
        cont.()

      %{key: :up} ->
        TuiState.put_pidx(state, TuiState.pidx(state) - 1)
        draw.()
        cont.()

      %{key: :enter} ->
        line = choice(state)
        close(state)

        case submit.(line) do
          {:submit, line} -> {:submit, line}
          :continue -> cont.()
          :exit -> :exit
        end

      %{key: :backspace} ->
        edit_and_redraw(event, state, draw, cont, close_when_empty?: true)

      %{key: key} when key in @edit_keys ->
        edit_and_redraw(event, state, draw, cont, close_when_empty?: true)

      %{key: :char, char: grapheme} when is_binary(grapheme) ->
        edit_and_redraw(event, state, draw, cont)

      %{key: :paste, char: text} when is_binary(text) ->
        edit_and_redraw(event, state, draw, cont)

      _ignored ->
        cont.()
    end
  end

  @spec close(pid()) :: :ok
  def close(state) do
    TuiState.put_mode(state, :normal)
    _ = TuiState.take_buffer(state)
    TuiState.put_pidx(state, 0)
    :ok
  end

  @spec choice(pid()) :: String.t()
  def choice(state) do
    entries = Palette.filter(Palette.entries(), TuiState.buffer(state))

    case Palette.selected(entries, TuiState.pidx(state)) do
      %{slash: slash} -> slash
      _ -> String.trim(TuiState.buffer(state))
    end
  end

  defp edit_and_redraw(event, state, draw, cont, opts \\ []) do
    TuiState.edit_buffer(state, event)

    if Keyword.get(opts, :close_when_empty?, false) and TuiState.buffer(state) == "",
      do: close(state)

    TuiState.put_pidx(state, 0)
    draw.()
    cont.()
  end
end
