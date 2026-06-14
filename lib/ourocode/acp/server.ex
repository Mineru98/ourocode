defmodule Ourocode.Acp.Server do
  @moduledoc """
  ACP (Agent Client Protocol) stdio agent: `ourocode --acp`.

  Editors that speak ACP (Zed and friends) launch this as a subprocess and
  drive it over newline-delimited JSON-RPC on stdio. The server maps ACP
  sessions onto the same pieces the TUI chat lane uses — `Model.Catalog`
  for backend selection and `Model.Conversation` for multi-turn memory —
  so an editor gets the identical dialogue behaviour: streamed chunks as
  `session/update` notifications and turn cancellation via `session/cancel`.

  stdout carries only protocol frames; diagnostics belong on stderr.
  """

  alias Ourocode.Acp.Protocol
  alias Ourocode.Model
  alias Ourocode.Model.Catalog
  alias Ourocode.Model.Conversation

  @parse_error -32700
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  @doc """
  Runs the agent until stdin closes. `:input`, `:output`, and `:model` are
  injectable for tests; defaults speak stdio with the detected default model.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    input = Keyword.get(opts, :input, :stdio)
    output = Keyword.get(opts, :output, :stdio)
    model = Keyword.get_lazy(opts, :model, &resolve_model/0)
    new_session_id = Keyword.get(opts, :new_session_id, &generate_session_id/0)

    server = self()
    spawn_link(fn -> read_loop(server, input) end)

    loop(%{
      output: output,
      model: model,
      sessions: %{},
      turn: nil,
      new_session_id: new_session_id,
      version: version()
    })
  end

  # --- main loop ------------------------------------------------------------

  defp loop(state) do
    receive do
      {:stdin_line, line} ->
        loop(handle_line(line, state))

      :stdin_eof ->
        # The client is done sending; let an in-flight turn finish (its
        # frames may still be readable) instead of killing it mid-answer.
        drain_active_turn(state)

      {:chat_chunk, chunk} ->
        case state.turn do
          %{session_id: session_id} ->
            write(state, Protocol.agent_message_chunk(session_id, chunk))

          nil ->
            :ok
        end

        loop(state)

      {:chat_outcome, pid, outcome} ->
        loop(finish_turn(state, pid, outcome))

      {:DOWN, _ref, :process, pid, reason} ->
        loop(turn_down(state, pid, reason))
    end
  end

  defp drain_active_turn(%{turn: nil}), do: :ok

  defp drain_active_turn(state) do
    receive do
      {:chat_chunk, chunk} ->
        write(state, Protocol.agent_message_chunk(state.turn.session_id, chunk))
        drain_active_turn(state)

      {:chat_outcome, pid, outcome} ->
        drain_active_turn(finish_turn(state, pid, outcome))

      {:DOWN, _ref, :process, pid, reason} ->
        drain_active_turn(turn_down(state, pid, reason))
    after
      120_000 ->
        halt_turn(state)
        :ok
    end
  end

  defp read_loop(server, input) do
    case IO.read(input, :line) do
      :eof ->
        send(server, :stdin_eof)

      {:error, _reason} ->
        send(server, :stdin_eof)

      line ->
        send(server, {:stdin_line, line})
        read_loop(server, input)
    end
  end

  # --- dispatch ---------------------------------------------------------------

  defp handle_line(line, state) do
    case Protocol.decode(line) do
      {:request, id, method, params} ->
        handle_request(method, id, params, state)

      {:notification, method, params} ->
        handle_notification(method, params, state)

      {:invalid, id} ->
        write(state, Protocol.error(id, @parse_error, "invalid JSON-RPC frame"))
        state
    end
  end

  defp handle_request("initialize", id, _params, state) do
    write(state, Protocol.result(id, Protocol.initialize_result(state.version)))
    state
  end

  defp handle_request("session/new", id, params, state) do
    case params do
      %{"cwd" => cwd} when is_binary(cwd) ->
        session_id = state.new_session_id.()
        write(state, Protocol.result(id, %{"sessionId" => session_id}))

        put_in(state.sessions[session_id], %{cwd: cwd, conversation: Conversation.new()})

      _missing_cwd ->
        write(state, Protocol.error(id, @invalid_params, "session/new requires an absolute cwd"))
        state
    end
  end

  defp handle_request("session/prompt", id, params, state) do
    session_id = params["sessionId"]
    text = Protocol.prompt_text(params)

    cond do
      state.turn != nil ->
        write(state, Protocol.error(id, @internal_error, "a prompt turn is already in progress"))
        state

      not is_map_key(state.sessions, session_id) ->
        write(state, Protocol.error(id, @invalid_params, "unknown sessionId"))
        state

      text == "" ->
        write(state, Protocol.error(id, @invalid_params, "prompt has no text content"))
        state

      not Model.ready?(state.model) ->
        write(
          state,
          Protocol.error(
            id,
            @internal_error,
            "model backend unavailable; run ourocode interactively to sign in"
          )
        )

        state

      true ->
        start_turn(state, id, session_id, text)
    end
  end

  defp handle_request(method, id, _params, state) do
    write(state, Protocol.error(id, @method_not_found, "method not supported: " <> method))
    state
  end

  defp handle_notification("session/cancel", %{"sessionId" => session_id}, state) do
    case state.turn do
      %{session_id: ^session_id, id: id, pid: pid, ref: ref} ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        # The spec requires answering the pending prompt with the
        # `cancelled` stop reason once the turn is torn down.
        write(state, Protocol.result(id, %{"stopReason" => "cancelled"}))
        %{state | turn: nil}

      _other ->
        state
    end
  end

  defp handle_notification(_method, _params, state), do: state

  # --- prompt turn ------------------------------------------------------------

  defp start_turn(state, id, session_id, text) do
    server = self()
    model = state.model
    conversation = state.sessions[session_id].conversation
    stream_opts = [session_id: session_id, history: conversation]

    {pid, ref} =
      spawn_monitor(fn ->
        outcome =
          Model.stream(model, text, stream_opts, fn chunk ->
            send(server, {:chat_chunk, chunk})
          end)

        send(server, {:chat_outcome, self(), outcome})
      end)

    %{state | turn: %{id: id, pid: pid, ref: ref, session_id: session_id, text: text}}
  end

  defp finish_turn(%{turn: %{pid: pid} = turn} = state, pid, outcome) do
    Process.demonitor(turn.ref, [:flush])

    state =
      case outcome do
        {:ok, full} ->
          write(state, Protocol.result(turn.id, %{"stopReason" => "end_turn"}))

          update_in(state.sessions[turn.session_id].conversation, fn conversation ->
            Conversation.add_turn(conversation, turn.text, full)
          end)

        {:error, reason} ->
          write(
            state,
            Protocol.error(turn.id, @internal_error, "turn failed: #{inspect(reason)}")
          )

          state
      end

    %{state | turn: nil}
  end

  defp finish_turn(state, _stale_pid, _outcome), do: state

  defp turn_down(%{turn: %{pid: pid} = turn} = state, pid, reason) do
    write(state, Protocol.error(turn.id, @internal_error, "turn crashed: #{inspect(reason)}"))
    %{state | turn: nil}
  end

  defp turn_down(state, _pid, _reason), do: state

  defp halt_turn(%{turn: %{pid: pid, ref: ref}}) do
    Process.exit(pid, :kill)
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp halt_turn(_state), do: :ok

  # --- io ---------------------------------------------------------------------

  defp write(state, frame), do: IO.puts(state.output, frame)

  defp generate_session_id do
    "sess_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  # Editors configure their agent through env vars, so OUROCODE_MODEL picks
  # the backend for the whole ACP process; otherwise the detected default
  # (the same one the TUI would use) serves.
  defp resolve_model do
    case model_id_from_env(System.get_env("OUROCODE_MODEL")) do
      nil -> Catalog.default()
      id -> Catalog.fetch(Catalog.list(), id) || Catalog.default()
    end
  end

  @doc false
  @spec model_id_from_env(String.t() | nil) :: atom() | nil
  def model_id_from_env(value) do
    case value do
      "codex" -> :codex
      "claude" -> :claude_api
      "claude_api" -> :claude_api
      "gemini" -> :gemini
      _other -> nil
    end
  end

  defp version do
    case :application.get_key(:ourocode, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _other -> "0.0.0"
    end
  end
end
