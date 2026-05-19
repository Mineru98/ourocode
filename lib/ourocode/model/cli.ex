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
  def args(:codex_cli, prompt), do: ["exec", prompt]
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
      path -> run(path, args(id, prompt), on_chunk)
    end
  end

  defp run(path, args, on_chunk) do
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

    collect(port, [], on_chunk)
  end

  defp collect(port, acc, on_chunk) do
    receive do
      {^port, {:data, data}} ->
        on_chunk.(data)
        collect(port, [data | acc], on_chunk)

      {^port, {:exit_status, 0}} ->
        {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status}}
    after
      180_000 ->
        safe_close(port)
        {:error, :timeout}
    end
  end

  defp safe_close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
