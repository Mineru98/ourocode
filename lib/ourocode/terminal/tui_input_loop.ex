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
  @drain_byte_budget 1_048_576

  @spec read_line(map(), pid(), pid(), callbacks()) :: String.t() | :eof
  def read_line(result, output, state, callbacks) do
    {columns, rows} = TuiDriverSession.refresh_size(state)
    redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
    read_key_loop(result, output, state, callbacks)
  end

  @doc false
  @spec handle_events([map()], map(), pid(), pid(), pos_integer(), pos_integer(), callbacks()) ::
          :continue | :exit | {:submit, String.t()}
  def handle_events(events, result, output, state, columns, rows, callbacks) do
    case handle_events_with_rest(events, result, output, state, columns, rows, callbacks) do
      {:submit, line, _rest} -> {:submit, line}
      outcome -> outcome
    end
  end

  defp handle_events_with_rest(events, result, output, state, columns, rows, callbacks) do
    redraw_key = {__MODULE__, make_ref()}
    Process.put(redraw_key, false)

    try do
      outcome =
        process_events(events, result, output, state, columns, rows, callbacks, fn ->
          Process.put(redraw_key, true)
        end)

      if outcome != :exit and Process.get(redraw_key) do
        redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
      end

      outcome
    after
      Process.delete(redraw_key)
    end
  end

  defp process_events([], _result, _output, _state, _columns, _rows, _callbacks, _draw),
    do: :continue

  defp process_events([event | rest], result, output, state, columns, rows, callbacks, draw) do
    cont = fn -> process_events(rest, result, output, state, columns, rows, callbacks, draw) end

    cond do
      match?(%{key: :ctrl_c}, event) ->
        :exit

      TuiInteraction.capturing?(result, state) and TuiInteraction.selection_active?(result) and
          TuiInteraction.nav_event?(event, TuiState.buffer(state), result, state) ->
        TuiInteraction.handle_nav(event, result, state)
        draw.()
        cont.()

      TuiInteraction.mcp_ledger_active?(state) and
          TuiInteraction.nav_event?(event, TuiState.buffer(state), result, state) ->
        TuiInteraction.handle_nav(event, result, state)
        draw.()
        cont.()

      TuiInteraction.capturing?(result, state) and
        match?(%{key: k} when k in [:enter, :escape], event) and
          not command_submit?(event, state) ->
        TuiInteraction.handle_event(event, result, output, state)
        draw.()
        cont.()

      TuiInteraction.mcp_ledger_active?(state) and match?(%{key: :enter}, event) and
          TuiState.buffer(state) == "" ->
        TuiInteraction.handle_event(event, result, output, state)
        draw.()
        cont.()

      true ->
        handle_normal_event(event, result, output, state, columns, rows, callbacks, cont, draw)
    end
    |> preserve_unconsumed_events(rest)
  end

  @doc false
  @spec handle_tick(map(), pid(), pid(), pos_integer(), pos_integer(), callbacks()) ::
          :continue | :exit | {:submit, String.t()}
  def handle_tick(result, output, state, columns, rows, callbacks) do
    case TuiState.take_leftover(state) do
      <<27>> ->
        handle_events(
          [%{type: :key, key: :escape, char: nil}],
          result,
          output,
          state,
          columns,
          rows,
          callbacks
        )

      leftover ->
        TuiState.put_leftover(state, leftover)

        unless pending_cancel_prefix?(result, state) do
          redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
        end

        :continue
    end
  end

  defp read_key_loop(result, output, state, callbacks) do
    case TuiState.take_pending_events(state) do
      {[], :eof} -> :eof
      {[], :continue} -> read_chunk_loop(result, output, state, callbacks)
      {events, terminal} -> handle_read_events(events, terminal, result, output, state, callbacks)
    end
  end

  defp read_chunk_loop(result, output, state, callbacks) do
    case next_chunk(callbacks, state) do
      :eof ->
        :eof

      :tick ->
        {columns, rows} = TuiDriverSession.refresh_size(state)

        case handle_tick(result, output, state, columns, rows, callbacks) do
          {:submit, line} -> line
          :exit -> :eof
          :continue -> read_key_loop(result, output, state, callbacks)
        end

      {:resize, {columns, rows}} ->
        redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
        read_key_loop(result, output, state, callbacks)

      {:control, :redraw} ->
        {columns, rows} = TuiState.size(state)
        redraw(callbacks, result, output, state, TuiState.buffer(state), columns, rows)
        read_key_loop(result, output, state, callbacks)

      {:ok, chunk} ->
        {chunks, terminal} =
          drain_queued_chunks(state, callbacks, [chunk], byte_size(chunk))

        events = decode_chunks(chunks, state)
        handle_read_events(events, terminal, result, output, state, callbacks)
    end
  end

  defp handle_read_events(events, terminal, result, output, state, callbacks) do
    {columns, rows} = TuiDriverSession.refresh_size(state)

    case handle_events_with_rest(events, result, output, state, columns, rows, callbacks) do
      {:submit, line, rest} ->
        TuiState.put_pending_events(state, rest, terminal)
        line

      :exit ->
        :eof

      :continue when terminal == :eof ->
        :eof

      :continue ->
        read_key_loop(result, output, state, callbacks)
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
      interview_capturing?: TuiInteraction.capturing?(result, state),
      test_run?: Map.fetch!(callbacks, :test_run?)
    })
  end

  defp next_chunk(callbacks, state, poll_ms \\ nil) do
    case TuiState.take_inbuf(state) do
      "" ->
        case Map.get(callbacks, :next_chunk) do
          next_chunk when is_function(next_chunk, 2) -> next_chunk.(state, poll_ms)
          next_chunk when is_function(next_chunk, 1) -> next_chunk.(state)
          _other when is_nil(poll_ms) -> TuiDriverSession.next_chunk(state)
          _other -> TuiDriverSession.next_chunk(state, poll_ms)
        end

      buffered ->
        {:ok, buffered}
    end
  end

  # Drain already-queued messages without waiting for more input. The byte budget
  # keeps a continuously busy Port from starving redraw while allowing normal
  # bursts of many small chunks to remain a single frame.
  defp drain_queued_chunks(_state, _callbacks, chunks, bytes)
       when bytes >= @drain_byte_budget,
       do: {Enum.reverse(chunks), :continue}

  defp drain_queued_chunks(state, callbacks, chunks, bytes) do
    case next_chunk(callbacks, state, 0) do
      {:ok, chunk} ->
        if bytes + byte_size(chunk) > @drain_byte_budget do
          TuiState.put_inbuf(state, chunk)
          {Enum.reverse(chunks), :continue}
        else
          drain_queued_chunks(state, callbacks, [chunk | chunks], bytes + byte_size(chunk))
        end

      :eof ->
        {Enum.reverse(chunks), :eof}

      _other ->
        {Enum.reverse(chunks), :continue}
    end
  end

  defp decode_chunks(chunks, state) do
    {events, leftover} =
      state
      |> TuiState.take_leftover()
      |> Kernel.<>(IO.iodata_to_binary(chunks))
      |> KeyReader.decode()

    TuiState.put_leftover(state, leftover)
    events
  end

  defp preserve_unconsumed_events({:submit, line}, rest), do: {:submit, line, rest}
  defp preserve_unconsumed_events(outcome, _rest), do: outcome

  defp command_submit?(%{key: :enter}, state) do
    state
    |> TuiState.buffer()
    |> String.trim_leading()
    |> command_like?()
  end

  defp command_submit?(_event, _state), do: false

  defp command_like?("/" <> _rest), do: true
  defp command_like?("ooo" <> rest), do: rest == "" or String.match?(rest, ~r/^\s/)
  defp command_like?(_line), do: false

  defp pending_cancel_prefix?(result, state) do
    buffer = TuiState.buffer(state)

    TuiInteraction.capturing?(result, state) and buffer != "" and
      String.starts_with?("/cancel", buffer)
  end

  defp redraw(callbacks, result, output, state, prompt_buffer, columns, rows) do
    Map.fetch!(callbacks, :redraw).(result, output, state, prompt_buffer, columns, rows)
  end
end
