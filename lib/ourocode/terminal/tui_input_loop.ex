defmodule Ourocode.Terminal.TuiInputLoop do
  @moduledoc """
  Key input loop for the interactive TUI.
  """

  alias Ourocode.Terminal.{
    KeyReader,
    TuiDriverSession,
    TuiInteraction,
    TuiNormalEvent,
    TuiState
  }

  @type callbacks :: %{
          required(:redraw) => (map(), pid(), pid(), String.t(), pos_integer(), pos_integer() ->
                                  any()),
          required(:choose_model) => (map(), pid(), pid(), pos_integer(), pos_integer() -> any()),
          required(:handle_enter) => (String.t(),
                                      map(),
                                      pid(),
                                      pid(),
                                      pos_integer(),
                                      pos_integer() ->
                                        :continue | :exit | {:submit, String.t()}),
          required(:test_run?) => (-> boolean())
        }

  @spec read_line(map(), pid(), pid(), callbacks()) :: String.t() | :eof
  def read_line(result, output, state, callbacks) do
    {columns, rows} = TuiDriverSession.refresh_size(state)
    redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
    read_key_loop(result, output, state, callbacks)
  end

  @doc false
  @spec handle_events([map()], map(), pid(), pid(), pos_integer(), pos_integer(), callbacks()) ::
          :continue | :exit | {:submit, String.t()}
  def handle_events(events, result, output, state, columns, rows, callbacks)

  def handle_events([], _result, _output, _state, _columns, _rows, _callbacks), do: :continue

  def handle_events([event | rest], result, output, state, columns, rows, callbacks) do
    cont = fn -> handle_events(rest, result, output, state, columns, rows, callbacks) end

    draw = fn ->
      redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
    end

    cond do
      match?(%{key: :ctrl_c}, event) ->
        :exit

      TuiInteraction.capturing?(result) and TuiInteraction.wonder_active?(result) and
          TuiInteraction.nav_event?(event, TuiState.buffer(state), result, state) ->
        TuiInteraction.handle_nav(event, result, state)
        draw.()
        cont.()

      TuiInteraction.capturing?(result) and
          match?(%{key: k} when k in [:enter, :escape], event) ->
        TuiInteraction.handle_event(event, result, output, state)
        draw.()
        cont.()

      true ->
        handle_normal_event(event, result, output, state, columns, rows, callbacks, cont, draw)
    end
  end

  defp read_key_loop(result, output, state, callbacks) do
    case TuiDriverSession.next_chunk(state) do
      :eof ->
        :eof

      :tick ->
        {columns, rows} = TuiDriverSession.refresh_size(state)
        redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
        read_key_loop(result, output, state, callbacks)

      {:ok, chunk} ->
        {columns, rows} = TuiDriverSession.refresh_size(state)
        {events, leftover} = KeyReader.decode(TuiState.take_leftover(state) <> chunk)
        TuiState.put_leftover(state, leftover)

        case handle_events(events, result, output, state, columns, rows, callbacks) do
          {:submit, line} -> line
          :exit -> :eof
          :continue -> read_key_loop(result, output, state, callbacks)
        end
    end
  end

  defp handle_normal_event(event, result, output, state, columns, rows, callbacks, cont, draw) do
    TuiNormalEvent.handle(event, state, %{
      choose_model: fn ->
        Map.fetch!(callbacks, :choose_model).(result, output, state, columns, rows)
      end,
      cont: cont,
      draw: draw,
      handle_enter: fn line ->
        Map.fetch!(callbacks, :handle_enter).(line, result, output, state, columns, rows)
      end,
      test_run?: Map.fetch!(callbacks, :test_run?)
    })
  end

  defp redraw(callbacks, result, output, state, prompt_buffer, columns, rows) do
    Map.fetch!(callbacks, :redraw).(result, output, state, prompt_buffer, columns, rows)
  end
end
