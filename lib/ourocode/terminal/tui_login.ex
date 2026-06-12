defmodule Ourocode.Terminal.TuiLogin do
  @moduledoc false

  alias Ourocode.Provider.Anthropic
  alias Ourocode.Provider.Codex
  alias Ourocode.Terminal.TuiState

  @max_login_polls 80

  @doc """
  Starts login for the chosen backend. Codex uses the device-code flow with
  a live card; Claude (Anthropic) opens the browser authorization URL and
  arms a paste-the-code step handled by the next submitted line.
  """
  @spec start(atom(), map(), pid(), pid(), pos_integer(), pos_integer(), function()) :: :ok
  def start(provider, result, output, state, cols, rows, redraw)

  def start(:claude_api, result, output, state, cols, rows, redraw)
      when is_function(redraw, 6) do
    pkce = Anthropic.generate_pkce()
    login_state = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    url = Anthropic.authorize_url(pkce.challenge, login_state)

    TuiState.put_pending_login(state, %{
      provider: :claude_api,
      verifier: pkce.verifier,
      state: login_state
    })

    log(output, "Open this URL, approve, then paste the code back here:")
    log(output, url)
    log(output, "(paste the authorization code and press Enter; /cancel to abort)")
    redraw.(result, output, state, "", cols, rows)
  end

  def start(_codex, result, output, state, cols, rows, redraw) when is_function(redraw, 6) do
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
            if transient_poll_error?(reason) do
              redraw.(result, output, state, "", cols, rows)
              poll(dev, polls + 1, result, output, state, cols, rows, redraw)
            else
              TuiState.put_login(state, nil)
              log(output, "Login failed: #{inspect(reason)}")
              redraw.(result, output, state, "", cols, rows)
            end
        end
    end
  end

  # One blip while the user is still typing the code must not abort the
  # login: transport errors and retryable statuses (408/429/5xx) keep polling
  # inside the @max_login_polls budget; only a definitive 4xx aborts.
  @doc false
  @spec transient_poll_error?(term()) :: boolean()
  def transient_poll_error?({:device_poll_failed, status, _body}) when is_integer(status),
    do: status in [408, 429] or status >= 500

  def transient_poll_error?(_transport_error), do: true

  @doc """
  Completes a pending paste-based login with the code the user submitted.
  Returns `:handled` (login attempt consumed the line) or `:not_pending`.
  """
  @spec complete_paste(String.t(), pid(), pid()) :: :handled | :not_pending
  def complete_paste(line, output, state) do
    case TuiState.pending_login(state) do
      %{provider: :claude_api, verifier: verifier, state: login_state} ->
        TuiState.put_pending_login(state, nil)
        code = line |> String.trim() |> strip_url_to_code()

        case Anthropic.exchange(code, verifier, login_state) do
          {:ok, tokens} ->
            TuiState.put_model_id(state, :claude_api)
            who = tokens.email || tokens.account_id || "your Claude account"
            log(output, "Signed in as #{who}. model: claude (Claude Pro/Max).")

          {:error, reason} ->
            log(output, "Claude login failed: #{inspect(reason)}")
        end

        :handled

      _none ->
        :not_pending
    end
  end

  # Accept either a bare code or the full redirect URL the browser landed on.
  defp strip_url_to_code(text) do
    case URI.parse(text) do
      %URI{query: query} when is_binary(query) ->
        case URI.decode_query(query) do
          %{"code" => code} = params ->
            case params["state"] do
              s when is_binary(s) and s != "" -> code <> "#" <> s
              _none -> code
            end

          _no_code ->
            text
        end

      _not_a_url ->
        text
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
