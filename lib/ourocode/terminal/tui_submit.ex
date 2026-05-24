defmodule Ourocode.Terminal.TuiSubmit do
  @moduledoc false

  alias Ourocode.Provider.Codex
  alias Ourocode.Terminal.{TuiChat, TuiInteraction, TuiLogin, TuiState}

  @spec handle(String.t(), map(), pid(), pid(), pos_integer(), pos_integer(), keyword()) ::
          :continue | :exit | {:submit, String.t()}
  def handle(line, result, output, state, cols, rows, callbacks \\ [])

  def handle("", _result, _output, _state, _cols, _rows, _callbacks), do: :continue

  def handle("/login", result, output, state, cols, rows, callbacks) do
    TuiLogin.start(result, output, state, cols, rows, redraw(callbacks))
    :continue
  end

  def handle("/logout", result, output, state, cols, rows, callbacks) do
    Codex.clear()
    log(output, "Signed out of ChatGPT.")
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/clear", result, output, state, cols, rows, callbacks) do
    clear_captured_output(output)
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/answer " <> answer, result, output, state, _cols, _rows, _callbacks) do
    TuiInteraction.submit_slash_answer(answer, result, output, state)
    :continue
  end

  def handle("/exit", _result, _output, _state, _cols, _rows, _callbacks), do: :exit
  def handle("/quit", _result, _output, _state, _cols, _rows, _callbacks), do: :exit

  def handle(line, result, output, state, cols, rows, callbacks)
      when line in ["/model", "/models"] do
    TuiState.put_mode(state, :model)
    TuiState.put_pidx(state, 0)
    redraw(callbacks).(result, output, state, "", cols, rows)
    :continue
  end

  def handle("/" <> _ = line, _result, _output, _state, _cols, _rows, _callbacks) do
    {:submit, line}
  end

  def handle("ooo" <> _ = line, result, output, state, cols, rows, callbacks) do
    redraw(callbacks).(result, output, state, "", cols, rows)
    {:submit, line}
  end

  def handle(prompt, result, output, state, cols, rows, callbacks) do
    TuiChat.chat(
      prompt,
      result,
      output,
      state,
      cols,
      rows,
      active_model(callbacks),
      redraw(callbacks)
    )

    :continue
  end

  defp redraw(callbacks), do: Keyword.fetch!(callbacks, :redraw)
  defp active_model(callbacks), do: Keyword.fetch!(callbacks, :active_model)

  defp log(output, text), do: IO.puts(output, text)

  defp clear_captured_output(output) do
    StringIO.flush(output)
    :ok
  rescue
    _exception -> :ok
  end
end
