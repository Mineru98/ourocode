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
        entry = selected_entry(state)

        if guided_work_entry?(entry) do
          close(state, selected_entry: entry)
          draw.()
          cont.()
        else
          line = choice_from_entry(entry, state)
          close(state)

          case submit.(line) do
            {:submit, line} -> {:submit, line}
            :continue -> cont.()
            :exit -> :exit
          end
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
  def close(state, opts \\ []) do
    TuiState.put_mode(state, :normal)

    buffer =
      case Keyword.get(opts, :selected_entry) do
        %{source: :guided_work, aliases: [alias | _]} -> alias <> " "
        _entry -> ""
      end

    Agent.update(state, fn tui_state ->
      %{tui_state | buffer: buffer, cursor: String.length(buffer)}
    end)

    TuiState.put_pidx(state, 0)
    :ok
  end

  @spec choice(pid()) :: String.t()
  def choice(state) do
    choice_from_entry(selected_entry(state), state)
  end

  defp selected_entry(state) do
    entries = Palette.filter(Palette.entries(), TuiState.buffer(state))
    Palette.selected(entries, TuiState.pidx(state))
  end

  defp choice_from_entry(entry, state) do
    case entry do
      %{slash: slash, args: [_ | _]} ->
        buffer = String.trim(TuiState.buffer(state))

        if String.starts_with?(buffer, slash <> " "), do: buffer, else: slash

      %{slash: slash} ->
        slash

      _ ->
        String.trim(TuiState.buffer(state))
    end
  end

  defp guided_work_entry?(%{source: :guided_work}), do: true
  defp guided_work_entry?(_entry), do: false

  defp edit_and_redraw(event, state, draw, cont, opts \\ []) do
    TuiState.edit_buffer(state, event)

    if Keyword.get(opts, :close_when_empty?, false) and TuiState.buffer(state) == "",
      do: close(state)

    TuiState.put_pidx(state, 0)
    draw.()
    cont.()
  end
end
