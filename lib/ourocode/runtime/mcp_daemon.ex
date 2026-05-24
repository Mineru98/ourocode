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

  # ~12s ceiling: a warm `uvx`/installed server binds in 2-3s; the first
  # uvx run may resolve deps. Non-fatal on timeout — the relay surfaces a
  # visible failure and the user can retry once the server is warm.
  @ready_attempts 60
  @ready_interval_ms 200

  alias Ourocode.Runtime.McpDaemon.Process, as: DaemonProcess
  alias Ourocode.Runtime.McpDaemon.Target

  @doc """
  Starts (or adopts) a local MCP server for the configured URL.

  Always returns `{:ok, handle}` — the `:mode` says what happened so callers
  can surface it without branching on errors.
  """
  @spec maybe_start(keyword()) :: {:ok, handle()}
  def maybe_start(opts \\ []) do
    spawn_fun = Keyword.get(opts, :spawn_fun, &DaemonProcess.spawn_server/3)
    llm_backend = Keyword.get(opts, :llm_backend)

    case resolve_target() do
      :disabled ->
        {:ok, %{mode: :disabled, url: mcp_url() || Target.default_url()}}

      {:external, url} ->
        {:ok, %{mode: :external, url: url}}

      {:spawn, host, port, url, explicit?} ->
        case spawn_fun.(host, port, llm_backend) do
          {:ok, erl_port, os_pid} ->
            log_path = nil

            finish_spawn(explicit?, url, erl_port, os_pid, llm_backend, log_path,
              wait?: Keyword.get(opts, :wait?, true)
            )

          {:ok, erl_port, os_pid, log_path} ->
            finish_spawn(explicit?, url, erl_port, os_pid, llm_backend, log_path,
              wait?: Keyword.get(opts, :wait?, true)
            )

          :unavailable ->
            {:ok, %{mode: :unavailable, url: url}}
        end
    end
  rescue
    _exception -> {:ok, %{mode: :unavailable, url: mcp_url() || Target.default_url()}}
  end

  defp finish_spawn(explicit?, url, erl_port, os_pid, llm_backend, log_path, opts) do
    # Default (per-instance) launches own the URL: export it so
    # LoopBindings + the interview invocation in this BEAM target
    # *this* server, not the stale fixed-port default. An explicit
    # OUROCODE_MCP_URL is the operator's and is left untouched.
    unless explicit?, do: System.put_env("OUROCODE_MCP_URL", url)
    uri = URI.parse(url)
    await_ready(uri.host || "127.0.0.1", uri.port || 4000, Keyword.get(opts, :wait?, true))

    handle = %{
      mode: :spawned,
      port: erl_port,
      os_pid: os_pid,
      url: url,
      llm_backend: llm_backend
    }

    {:ok, if(is_binary(log_path), do: Map.put(handle, :log_path, log_path), else: handle)}
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
    Target.decide(disabled?(), mcp_url(), &port_open?/2, &free_port/0)
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
  def stop(handle), do: DaemonProcess.stop(handle)

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

  defp port_open?(host, port) do
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 300) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
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
