defmodule Ourocode.Terminal.TuiNormalEvent do
  @moduledoc """
  Normal-mode key handling for the interactive TUI.
  """

  alias Ourocode.Terminal.{
    TuiModelEvent,
    TuiNormalKey,
    TuiNormalNavigation,
    TuiNormalSubmit,
    TuiPalette,
    TuiState
  }

  @spec handle(map(), pid(), map()) :: :continue | :exit | {:submit, String.t()}
  def handle(event, state, callbacks) when is_map(callbacks) do
    draw = Map.fetch!(callbacks, :draw)
    cont = Map.fetch!(callbacks, :cont)

    case {TuiState.mode(state), event} do
      {_mode, %{key: :ctrl_c}} ->
        :exit

      {_mode, %{key: k}} when k in [:cmd_plus, :cmd_minus] ->
        draw.()
        cont.()

      {_mode, %{key: :ctrl_g}} ->
        TuiState.toggle_key_help(state)
        draw.()
        cont.()

      {:palette, palette_event} ->
        TuiPalette.handle_event(
          palette_event,
          state,
          Map.fetch!(callbacks, :handle_enter),
          draw,
          cont
        )

      {:model, model_event} ->
        TuiModelEvent.handle(model_event, state, callbacks, draw, cont)

      {:normal, %{key: down}} when down in [:down, :tab, :ctrl_n] ->
        handle_down(state, callbacks)
        draw.()
        cont.()

      {:normal, %{key: up}} when up in [:up, :ctrl_p] ->
        handle_up(state, callbacks)
        draw.()
        cont.()

      {:normal, %{key: :char, char: "/"}} ->
        if TuiState.buffer(state) == "" do
          TuiState.put_mode(state, :palette)
          TuiState.put_pidx(state, 0)
        end

        edit_and_redraw(state, event, draw, cont)

      {:normal, %{key: :enter}} ->
        handle_enter(state, callbacks, draw, cont)

      {:normal, %{key: :backspace}} ->
        edit_and_redraw(state, event, draw, cont)

      {:normal, %{key: :ctrl_d}} ->
        if TuiState.buffer(state) == "" do
          :exit
        else
          edit_and_redraw(state, event, draw, cont)
        end

      {:normal, %{key: :escape}} ->
        TuiState.handle_escape_clear(state)
        draw.()
        cont.()

      {:normal, %{key: :char, char: char}} when is_binary(char) ->
        edit_and_redraw(state, event, draw, cont)

      {:normal, %{key: :paste, char: text}} when is_binary(text) ->
        edit_and_redraw(state, event, draw, cont)

      {:normal, normal_event} ->
        handle_normal_fallback(normal_event, state, draw, cont)

      {_mode, scroll_event} ->
        case TuiNormalKey.scroll_delta(scroll_event) do
          delta when is_integer(delta) -> scroll_and_redraw(state, delta, draw, cont)
          nil -> cont.()
        end
    end
  end

  defp handle_down(state, callbacks) do
    TuiNormalNavigation.move_vertical(state, 1, test_run?(callbacks))
  end

  defp handle_up(state, callbacks) do
    TuiNormalNavigation.move_vertical(state, -1, test_run?(callbacks))
  end

  defp handle_enter(state, callbacks, draw, cont) do
    TuiNormalSubmit.handle(state, callbacks, draw, cont)
  end

  defp edit_and_redraw(state, event, draw, cont) do
    TuiState.edit_buffer(state, event)
    TuiState.put_pidx(state, 0)
    TuiState.reset_history_cursor(state)
    draw.()
    cont.()
  end

  defp scroll_and_redraw(state, delta, draw, cont) do
    TuiState.scroll_by(state, delta)
    draw.()
    cont.()
  end

  defp handle_normal_fallback(event, state, draw, cont) do
    cond do
      TuiNormalKey.editing?(event) ->
        edit_and_redraw(state, event, draw, cont)

      delta = TuiNormalKey.scroll_delta(event) ->
        scroll_and_redraw(state, delta, draw, cont)

      true ->
        cont.()
    end
  end

  defp test_run?(callbacks) do
    case Map.get(callbacks, :test_run?) do
      fun when is_function(fun, 0) -> fun.()
      _other -> false
    end
  end
end
