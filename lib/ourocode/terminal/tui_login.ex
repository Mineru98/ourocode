defmodule Ourocode.Terminal.TuiLogin do
  @moduledoc false

  alias Ourocode.Provider.Codex
  alias Ourocode.Terminal.TuiState

  @max_login_polls 80

  @spec start(map(), pid(), pid(), pos_integer(), pos_integer(), function()) :: :ok
  def start(result, output, state, cols, rows, redraw) when is_function(redraw, 6) do
    case Codex.start_device_login() do
      {:ok, dev} ->
        TuiState.put_login(state, %{code: dev.user_code, url: dev.verification_uri})
        redraw.(result, output, state, "", cols, rows)
        poll(dev, 0, result, output, state, cols, rows, redraw)

      {:error, reason} ->
        log(output, "Login could not start: #{inspect(reason)}")
        redraw.(result, output, state, "", cols, rows)
    end
  end

  defp poll(_dev, polls, result, output, state, cols, rows, redraw)
       when polls >= @max_login_polls do
    TuiState.put_login(state, nil)
    log(output, "Login timed out. Run /login to try again.")
    redraw.(result, output, state, "", cols, rows)
  end

  defp poll(dev, polls, result, output, state, cols, rows, redraw) do
    deadline = System.monotonic_time(:millisecond) + dev.interval_ms

    case wait_or_cancel(state, deadline) do
      :cancel ->
        TuiState.put_login(state, nil)
        log(output, "Login cancelled.")
        redraw.(result, output, state, "", cols, rows)

      :timeout ->
        case Codex.poll_device_login(dev) do
          {:ok, tokens} ->
            TuiState.put_login(state, nil)
            TuiState.put_model_id(state, :codex)
            who = tokens.email || tokens.account_id || "your ChatGPT account"
            log(output, "Signed in as #{who}. model: codex (ChatGPT) - ask anything.")
            redraw.(result, output, state, "", cols, rows)

          :pending ->
            redraw.(result, output, state, "", cols, rows)
            poll(dev, polls + 1, result, output, state, cols, rows, redraw)

          {:error, reason} ->
            TuiState.put_login(state, nil)
            log(output, "Login failed: #{inspect(reason)}")
            redraw.(result, output, state, "", cols, rows)
        end
    end
  end

  defp wait_or_cancel(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :timeout
    else
      port = TuiState.port(state)

      receive do
        {^port, {:data, data}} ->
          if String.contains?(data, <<3>>) or String.contains?(data, <<27>>),
            do: :cancel,
            else: wait_or_cancel(state, deadline)

        {^port, {:exit_status, _}} ->
          :cancel
      after
        remaining -> :timeout
      end
    end
  end

  defp log(output, text), do: IO.puts(output, text)
end
