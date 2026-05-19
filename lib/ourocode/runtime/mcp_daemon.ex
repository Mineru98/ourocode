defmodule Ourocode.Runtime.McpDaemon do
  @moduledoc """
  Best-effort lifecycle manager for a local Ouroboros MCP server.

  `ooo` workflows assume an Ouroboros MCP server is reachable. Rather than
  making the user start it by hand, ourocode can spawn it as a child process
  tied to the BEAM lifecycle and tear it down on exit.

  Concurrency model: **one dedicated server per ourocode instance**. Each
  launch picks a fresh ephemeral port and spawns its own server with the
  *current* `ouroboros config`, then exports that URL so the rest of this
  BEAM (LoopBindings, the interview invocation) talks to it. Opening
  ourocode in several tabs therefore gives each tab an isolated, up-to-date
  server — a new tab never restarts or kills another tab's server, and a
  stale long-lived server can't shadow a backend config change.

  This is intentionally conservative — the app must still work (degrading to
  a visible "failed" pane) when the daemon cannot start:

    * disabled when `OUROCODE_MCP_AUTOSTART=0`
    * when `OUROCODE_MCP_URL` is set explicitly the operator is pointing at
      their own server: adopt it if the port is open (`:external`), else
      spawn exactly there — never hijack an explicit target with a random
      port
    * default (no explicit URL): bind a free 127.0.0.1 port and spawn a
      per-instance server, exporting `OUROCODE_MCP_URL` for this process
    * skipped when neither `ouroboros` nor `uvx` is on PATH
    * never blocks the prompt loop and never raises into startup
    * not a supervised runtime service (no bootstrap_result/@service_ids
      ripple) — it is owned by the interactive launch path only

  The spawned server listens at `http://127.0.0.1:<port>/mcp`
  (`ouroboros mcp serve --transport streamable-http`).
  """

  @type handle :: %{
          required(:mode) => :spawned | :external | :disabled | :unavailable,
          optional(:port) => port(),
          optional(:os_pid) => non_neg_integer(),
          required(:url) => String.t()
        }

  @default_url "http://127.0.0.1:4000/mcp"
  # ~12s ceiling: a warm `uvx`/installed server binds in 2-3s; the first
  # uvx run may resolve deps. Non-fatal on timeout — the relay surfaces a
  # visible failure and the user can retry once the server is warm.
  @ready_attempts 60
  @ready_interval_ms 200

  @doc """
  Starts (or adopts) a local MCP server for the configured URL.

  Always returns `{:ok, handle}` — the `:mode` says what happened so callers
  can surface it without branching on errors.
  """
  @spec maybe_start(keyword()) :: {:ok, handle()}
  def maybe_start(opts \\ []) do
    spawn_fun = Keyword.get(opts, :spawn_fun, &spawn_server/2)

    case resolve_target() do
      :disabled ->
        {:ok, %{mode: :disabled, url: mcp_url() || @default_url}}

      {:external, url} ->
        {:ok, %{mode: :external, url: url}}

      {:spawn, host, port, url, explicit?} ->
        case spawn_fun.(host, port) do
          {:ok, erl_port, os_pid} ->
            # Default (per-instance) launches own the URL: export it so
            # LoopBindings + the interview invocation in this BEAM target
            # *this* server, not the stale fixed-port default. An explicit
            # OUROCODE_MCP_URL is the operator's and is left untouched.
            unless explicit?, do: System.put_env("OUROCODE_MCP_URL", url)
            await_ready(host, port, Keyword.get(opts, :wait?, true))
            {:ok, %{mode: :spawned, port: erl_port, os_pid: os_pid, url: url}}

          :unavailable ->
            {:ok, %{mode: :unavailable, url: url}}
        end
    end
  rescue
    _exception -> {:ok, %{mode: :unavailable, url: mcp_url() || @default_url}}
  end

  @doc """
  Pure launch decision (no side effects), so the conservative contract is
  unit-testable without spawning a real server.
  """
  @spec resolve_target() ::
          :disabled
          | {:external, String.t()}
          | {:spawn, String.t(), :inet.port_number(), String.t(), boolean()}
  def resolve_target do
    explicit = mcp_url()

    cond do
      disabled?() ->
        :disabled

      is_binary(explicit) ->
        {host, port} = host_port(explicit)

        if port_open?(host, port),
          do: {:external, explicit},
          else: {:spawn, host, port, explicit, true}

      true ->
        host = "127.0.0.1"
        port = free_port()
        {:spawn, host, port, "http://#{host}:#{port}/mcp", false}
    end
  end

  # A free ephemeral port: bind 0, read the assigned port, release it. The
  # tiny TOCTOU window before the server binds is acceptable — a per-instance
  # collision only degrades to a visible failure pane, never data loss.
  defp free_port do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(lsock)
    :gen_tcp.close(lsock)
    port
  end

  @doc """
  Stops a spawned server. No-op for adopted/disabled/unavailable handles.
  """
  @spec stop(handle() | nil) :: :ok
  def stop(%{mode: :spawned} = handle) do
    # Closing the Erlang port does NOT reliably reap the OS process (the
    # server is `exec`-ed under `sh` and never reads stdin). For the
    # per-instance model that would orphan a server on every tab close, so
    # signal the OS pid directly, then close the port.
    case Map.get(handle, :os_pid) do
      pid when is_integer(pid) and pid > 0 ->
        System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      _none ->
        :ok
    end

    erl_port = Map.get(handle, :port)
    if is_port(erl_port) and Port.info(erl_port) != nil, do: Port.close(erl_port)
    :ok
  rescue
    _exception -> :ok
  end

  def stop(_handle), do: :ok

  @doc "Human-readable one-liner for status output."
  @spec describe(handle()) :: String.t()
  def describe(%{mode: :spawned, url: url}), do: "ouroboros mcp: spawned at #{url}"
  def describe(%{mode: :external, url: url}), do: "ouroboros mcp: using existing server at #{url}"
  def describe(%{mode: :disabled}), do: "ouroboros mcp: autostart disabled"
  def describe(%{mode: :unavailable}), do: "ouroboros mcp: unavailable (install ouroboros-ai)"
  def describe(_handle), do: "ouroboros mcp: unknown"

  # --- internals -----------------------------------------------------------

  defp disabled?, do: System.get_env("OUROCODE_MCP_AUTOSTART") == "0"

  # nil (not the fixed default) when unset, so `resolve_target/0` can tell an
  # explicit operator target from the auto per-instance path.
  defp mcp_url, do: System.get_env("OUROCODE_MCP_URL")

  # Extracts host/port from http://host:port/path (defaults 127.0.0.1:4000).
  defp host_port(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4000}
  end

  defp port_open?(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  # Prefer a direct `ouroboros` binary; fall back to `uvx` (zero-install run)
  # exactly as the Claude plugin launches it.
  defp spawn_server(host, port) do
    case server_command(host, port) do
      {exe, args} ->
        sh = System.find_executable("sh") || "/bin/sh"
        log = Path.join(System.tmp_dir!(), "ourocode-mcp-#{port}.log")

        # Run the server with stdout+stderr redirected to a log file. Without
        # this the server's structured logs (stderr) inherit the BEAM's tty
        # and bleed onto the ourocode alt-screen, corrupting the TUI. The
        # `"$0" "$@"` form avoids any shell-quoting of exe/args.
        sh_args = ["-c", "exec \"$0\" \"$@\" >\"#{log}\" 2>&1", exe] ++ args

        erl_port =
          Port.open({:spawn_executable, sh}, [
            :binary,
            :exit_status,
            :hide,
            args: sh_args
          ])

        os_pid =
          case Port.info(erl_port, :os_pid) do
            {:os_pid, pid} -> pid
            _none -> nil
          end

        {:ok, erl_port, os_pid}

      :none ->
        :unavailable
    end
  end

  defp server_command(host, port) do
    serve_args = [
      "mcp",
      "serve",
      "--transport",
      "streamable-http",
      "--host",
      host,
      "--port",
      Integer.to_string(port)
    ]

    # Prefer `uvx` — it pins the exact `[mcp,claude]` extras on every run, so
    # the server can't boot-then-die with "mcp package not installed" the way
    # a globally-installed `ouroboros` binary does when its env lacks the mcp
    # extra. uvx caches the resolved env, so only the first run is slow. Bare
    # `ouroboros` is the fallback when uvx is unavailable.
    cond do
      exe = System.find_executable("uvx") ->
        {exe, ["--from", "ouroboros-ai[mcp,claude]", "ouroboros"] ++ serve_args}

      exe = System.find_executable("ouroboros") ->
        {exe, serve_args}

      true ->
        :none
    end
  end

  defp await_ready(_host, _port, false), do: :ok

  defp await_ready(host, port, true), do: await_ready(host, port, @ready_attempts)

  defp await_ready(_host, _port, 0), do: :timeout

  defp await_ready(host, port, attempts) do
    if port_open?(host, port) do
      :ok
    else
      Process.sleep(@ready_interval_ms)
      await_ready(host, port, attempts - 1)
    end
  end
end
