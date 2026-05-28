defmodule Ourocode.Model.Cli do
  @moduledoc """
  Streams a turn through a locally-installed agent CLI.

  These backends need no login: if the developer already uses `claude`,
  `codex`, or `gemini` from their terminal, that CLI carries its own
  session. We just run it non-interactively for one prompt and stream its
  stdout through the same render path as everything else.
  """

  @bins %{claude: "claude", codex_cli: "codex", gemini: "gemini"}

  @doc "Known CLI backend ids keyed to their binary name."
  @spec specs() :: %{atom() => String.t()}
  def specs, do: @bins

  @doc "Non-interactive argv for a one-shot prompt, per CLI."
  @spec args(atom(), String.t()) :: [String.t()]
  def args(:claude, prompt), do: ["-p", prompt]

  def args(:codex_cli, prompt),
    do: ["exec", "--json", "--color", "never", "--ephemeral", "--skip-git-repo-check", prompt]

  def args(:gemini, prompt), do: ["-p", prompt]

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
      nil -> {:error, {:not_installed, bin}}
      path -> run(id, path, args(id, prompt), on_chunk)
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

  defp handle_output(_id, data, acc, on_chunk) do
    on_chunk.(data)
    {[data | acc], ""}
  end

  defp flush_output(:codex_cli, "", acc, _on_chunk), do: {acc, ""}

  defp flush_output(:codex_cli, partial, acc, on_chunk),
    do: handle_output(:codex_cli, partial <> "\n", acc, on_chunk)

  defp flush_output(_id, partial, acc, on_chunk) do
    if partial != "" do
      on_chunk.(partial)
      {[partial | acc], ""}
    else
      {acc, ""}
    end
  end

  defp final_text(:codex_cli, [latest | _rest]), do: latest
  defp final_text(_id, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

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
