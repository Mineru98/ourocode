defmodule Ourocode.Terminal.TuiNormalSubmit do
  @moduledoc false

  alias Ourocode.Terminal.{TuiCompletions, TuiState}

  @spec handle(pid(), map(), (-> any()), (-> any())) ::
          :continue | :exit | {:submit, String.t()}
  def handle(state, callbacks, draw, cont)
      when is_pid(state) and is_map(callbacks) and is_function(draw, 0) and is_function(cont, 0) do
    if TuiCompletions.file_mention_suggesting?(state) do
      TuiCompletions.insert_file_mention_choice(state)
      TuiState.put_pidx(state, 0)
      draw.()
      cont.()
    else
      submit_buffer(state, callbacks, cont)
    end
  end

  defp submit_buffer(state, callbacks, cont) do
    line = submitted_line(state, callbacks)

    _ = TuiState.take_buffer(state)
    TuiState.put_pidx(state, 0)
    TuiState.remember_history(state, line)

    case Map.fetch!(callbacks, :handle_enter).(line) do
      {:submit, line} -> {:submit, line}
      :continue -> cont.()
      :exit -> :exit
    end
  end

  defp submitted_line(state, callbacks) do
    test_run? = test_run?(callbacks)

    if TuiCompletions.ooo_suggesting?(state, test_run?) do
      TuiCompletions.ooo_choice(
        TuiState.buffer(state),
        TuiState.pidx(state),
        state,
        test_run?
      )
    else
      String.trim(TuiState.buffer(state))
    end
  end

  defp test_run?(callbacks) do
    case Map.get(callbacks, :test_run?) do
      fun when is_function(fun, 0) -> fun.()
      _other -> false
    end
  end
end
