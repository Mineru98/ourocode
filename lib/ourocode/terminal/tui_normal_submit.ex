defmodule Ourocode.Terminal.TuiNormalSubmit do
  @moduledoc false

  alias Ourocode.Terminal.{TuiCompletions, TuiState}

  @spec handle(pid(), map(), (-> any()), (-> any())) ::
          :continue | :exit | {:submit, String.t()}
  def handle(state, callbacks, draw, cont)
      when is_pid(state) and is_map(callbacks) and is_function(draw, 0) and is_function(cont, 0) do
    cond do
      TuiCompletions.insert_active_choice(state, test_run?(callbacks)) ->
        draw.()
        cont.()

      workspace_action = workspace_enter_action(state) ->
        handle_workspace_action(workspace_action, state, callbacks, draw, cont)

      true ->
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

  defp handle_workspace_action(line, state, callbacks, draw, cont) do
    if placeholder_command?(line) do
      insert_workspace_template(line, state)
      draw.()
      cont.()
    else
      submit_workspace_action(line, state, callbacks, cont)
    end
  end

  defp submit_workspace_action(line, state, callbacks, cont) do
    TuiState.put_pidx(state, 0)
    TuiState.remember_history(state, line)

    case Map.fetch!(callbacks, :handle_enter).(line) do
      {:submit, line} -> {:submit, line}
      :continue -> cont.()
      :exit -> :exit
    end
  end

  defp workspace_enter_action(state) do
    if TuiState.buffer(state) == "" and TuiState.workspace_active?(state) do
      TuiState.workspace_enter_action(state)
    end
  end

  defp placeholder_command?(line), do: String.contains?(line, ["<", ">"])

  defp insert_workspace_template(line, state) do
    buffer =
      line
      |> String.replace(~r/\s*<[^>]+>/, " ")
      |> String.replace(~r/\s+/, " ")

    Agent.update(state, fn tui_state ->
      %{tui_state | buffer: buffer, cursor: String.length(buffer), pidx: 0}
    end)
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
