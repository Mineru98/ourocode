defmodule Ourocode.Model.Cli do
  @moduledoc """
  Streams a turn through a locally-installed agent CLI.

  These backends need no login: if the developer already uses `claude`,
  `codex`, or `gemini` from their terminal, that CLI carries its own
  session. We just run it non-interactively for one prompt and stream its
  stdout through the same render path as everything else.
  """

  @bins %{claude: "claude", codex_cli: "codex", gemini: "gemini"}

  # Replay-safe retry only: a CLI that exits non-zero before emitting any
  # chunk can be relaunched without the user seeing duplicate output. Once a
  # chunk has reached the renderer — or the run timed out after streaming —
  # the failure surfaces immediately.
  @max_attempts 3
  @retry_base_delay_ms 1_000

  @doc "Known CLI backend ids keyed to their binary name."
  @spec specs() :: %{atom() => String.t()}
  def specs, do: @bins

  @doc """
  Non-interactive argv for a one-shot prompt, per CLI. `system` is the
  ourocode identity prompt; claude takes it via --append-system-prompt so the
  CLI answers as ourocode. codex/gemini have no equivalent flag and prefer
  the direct-API path for identity, so they ignore it here.
  """
  @spec args(atom(), String.t(), String.t() | nil) :: [String.t()]
  def args(id, prompt, system \\ nil)

  def args(:claude, prompt, system) do
    append =
      case system do
        text when is_binary(text) and text != "" -> ["--append-system-prompt", text]
        _none -> []
      end

    ["-p", "--verbose", "--output-format", "stream-json", "--include-partial-messages"] ++
      append ++ [prompt]
  end

  def args(:codex_cli, prompt, _system),
    do: ["exec", "--json", "--color", "never", "--ephemeral", "--skip-git-repo-check", prompt]

  def args(:gemini, prompt, _system), do: ["-p", prompt]

  @doc "Absolute path of a CLI backend's binary, or nil if not installed."
  @spec resolve(atom(), (String.t() -> String.t() | nil)) :: String.t() | nil
  def resolve(id, which) when is_function(which, 1) do
    case Map.fetch(@bins, id) do
      {:ok, bin} -> which.(bin)
      :error -> nil
    end
  end

  @doc """
  Runs the CLI for one prompt, invoking `on_chunk` for each stdout chunk.

  Returns `{:ok, full_text}` on a clean exit, `{:error, {:exit, status}}`
  otherwise.
  """
  @spec stream(atom(), String.t(), keyword(), (String.t() -> any())) ::
          {:ok, String.t()} | {:error, term()}
  def stream(id, prompt, opts, on_chunk) when is_binary(prompt) and is_function(on_chunk, 1) do
    which = Keyword.get(opts, :which, &System.find_executable/1)
    bin = Map.fetch!(@bins, id)

    case which.(bin) do
      nil ->
        {:error, {:not_installed, bin}}

      path ->
        delay = Keyword.get(opts, :retry_base_delay_ms, @retry_base_delay_ms)
        system = Keyword.get(opts, :system, Ourocode.Prompt.system())
        run_with_retry(id, path, args(id, prompt, system), on_chunk, delay, 1)
    end
  end

  defp run_with_retry(id, path, args, on_chunk, delay, attempt) do
    emitted = :counters.new(1, [])

    counted_chunk = fn chunk ->
      :counters.add(emitted, 1, 1)
      on_chunk.(chunk)
    end

    case run(id, path, args, counted_chunk) do
      {:error, {:exit, _status}} = error ->
        if :counters.get(emitted, 1) == 0 and attempt < @max_attempts do
          Process.sleep(delay * Integer.pow(2, attempt - 1))
          run_with_retry(id, path, args, on_chunk, delay, attempt + 1)
        else
          error
        end

      other ->
        other
    end
  end

  defp run(id, path, args, on_chunk) do
    # Spawn through `sh -c 'exec "$0" "$@" </dev/null'` so the CLI's stdin is
    # /dev/null, not the BEAM port pipe. Otherwise `claude -p` / `codex exec`
    # block waiting for piped stdin (codex hangs on "Reading additional
    # input from stdin..."). Args are passed positionally, so the prompt
    # needs no shell escaping.
    shell = System.find_executable("sh") || "/bin/sh"

    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: ["-c", ~s(exec "$0" "$@" </dev/null), path | args]
      ])

    collect(id, port, [], "", on_chunk)
  end

  defp collect(id, port, acc, partial, on_chunk) do
    receive do
      {^port, {:data, data}} ->
        {acc, partial} = handle_output(id, partial <> data, acc, on_chunk)
        collect(id, port, acc, partial, on_chunk)

      {^port, {:exit_status, 0}} ->
        {acc, _partial} = flush_output(id, partial, acc, on_chunk)
        {:ok, final_text(id, acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      180_000 ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp handle_output(:codex_cli, data, acc, on_chunk) do
    {lines, partial} = complete_lines(data)

    acc =
      Enum.reduce(lines, acc, fn line, acc ->
        case codex_agent_text(line) do
          nil ->
            acc

          text ->
            on_chunk.(text)
            [text | acc]
        end
      end)

    {acc, partial}
  end

  defp handle_output(:claude, data, acc, on_chunk) do
    {lines, partial} = complete_lines(data)

    acc =
      Enum.reduce(lines, acc, fn line, acc ->
        case claude_stream_text(line) do
          nil ->
            acc

          {:delta, text} ->
            on_chunk.(text)
            [text | acc]

          {:result, text} ->
            [{:result, text} | acc]
        end
      end)

    {acc, partial}
  end

  defp handle_output(_id, data, acc, on_chunk) do
    on_chunk.(data)
    {[data | acc], ""}
  end

  defp flush_output(id, "", acc, _on_chunk) when id in [:codex_cli, :claude], do: {acc, ""}

  defp flush_output(id, partial, acc, on_chunk) when id in [:codex_cli, :claude],
    do: handle_output(id, partial <> "\n", acc, on_chunk)

  defp flush_output(_id, partial, acc, on_chunk) do
    if partial != "" do
      on_chunk.(partial)
      {[partial | acc], ""}
    else
      {acc, ""}
    end
  end

  defp final_text(:codex_cli, [latest | _rest]), do: latest

  # Streamed text deltas are the answer; the final `result` event is a
  # fallback for runs that produced no partial chunks.
  defp final_text(:claude, acc) do
    deltas = acc |> Enum.reject(&match?({:result, _}, &1)) |> Enum.reverse()

    case IO.iodata_to_binary(deltas) do
      "" -> Enum.find_value(acc, "", &result_text/1)
      text -> text
    end
  end

  defp final_text(_id, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp result_text({:result, text}), do: text
  defp result_text(_entry), do: nil

  defp claude_stream_text(line) do
    case Ourocode.Json.decode(line) do
      {:ok,
       %{
         "type" => "stream_event",
         "event" => %{
           "type" => "content_block_delta",
           "delta" => %{"type" => "text_delta", "text" => text}
         }
       }}
      when is_binary(text) ->
        {:delta, text}

      {:ok, %{"type" => "result", "result" => text}} when is_binary(text) ->
        {:result, text}

      _other ->
        nil
    end
  end

  defp complete_lines(data) do
    parts = String.split(data, "\n")

    case parts do
      [partial] ->
        {[], partial}

      _ ->
        {Enum.drop(parts, -1), List.last(parts)}
    end
  end

  defp codex_agent_text(line) do
    with {:ok, %{"type" => "item.completed", "item" => item}} <- Ourocode.Json.decode(line),
         %{"type" => "agent_message", "text" => text} when is_binary(text) <- item do
      text
    else
      _other -> nil
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
