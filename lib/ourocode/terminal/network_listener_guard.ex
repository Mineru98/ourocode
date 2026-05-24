defmodule Ourocode.Terminal.NetworkListenerGuard do
  @moduledoc """
  Startup guard for terminal-only listener boundaries.

  Terminal bootstrap may initialize client-side MCP transports, but it must not
  create or bind HTTP, WebSocket, or SSE listener surfaces. This guard verifies
  the startup source boundary and the live OTP process/application snapshot.
  """

  alias Ourocode.Terminal.NetworkListenerConfig
  alias Ourocode.Terminal.NetworkListenerBoundary

  @startup_source_files [
    "lib/ourocode/cli.ex",
    "lib/ourocode/terminal/application.ex",
    "lib/ourocode/terminal/root_ui.ex",
    "lib/ourocode/terminal/event_loop.ex",
    "lib/ourocode/terminal/shell_renderer.ex",
    "lib/ourocode/terminal/browser_runtime_guard.ex",
    "lib/ourocode/runtime/application.ex"
  ]

  @type report :: %{
          required(:status) => :terminal_listener_free,
          required(:listener_protocols_forbidden) => [atom()],
          required(:started_listener_apps) => [map()],
          required(:registered_listener_processes) => [map()],
          required(:startup_source_listener_calls) => [map()],
          required(:checked_at_ms) => integer()
        }

  @doc """
  Verifies that terminal startup has not configured or started listener
  protocols.
  """
  @spec verify_startup_boundary(keyword() | map()) :: {:ok, report()} | {:error, map()}
  def verify_startup_boundary(options \\ []) do
    options = Map.new(options)
    snapshot = Map.get(options, :listener_snapshot, default_listener_snapshot())
    source_files = Map.get(options, :source_files, @startup_source_files)

    started_listener_apps = NetworkListenerBoundary.started_listener_apps(snapshot)

    registered_listener_processes =
      NetworkListenerBoundary.registered_listener_processes(snapshot)

    startup_source_listener_calls =
      NetworkListenerBoundary.startup_source_listener_calls(source_files)

    if started_listener_apps == [] and registered_listener_processes == [] and
         startup_source_listener_calls == [] do
      {:ok,
       report(started_listener_apps, registered_listener_processes, startup_source_listener_calls)}
    else
      {:error,
       %{
         status: :unhealthy,
         healthy?: false,
         reason: :terminal_startup_listener_boundary_violation,
         listener_protocols_forbidden: NetworkListenerBoundary.listener_protocols(),
         started_listener_apps: started_listener_apps,
         registered_listener_processes: registered_listener_processes,
         startup_source_listener_calls: startup_source_listener_calls
       }}
    end
  end

  @doc """
  Verifies that core terminal interaction can validate and start without a
  locally configured HTTP, WebSocket, or SSE server endpoint.

  MCP HTTP/SSE client transports are intentionally separate from this check:
  they may be configured later as transport clients, but the terminal prompt
  loop itself must not depend on a listener/server endpoint.
  """
  @spec verify_core_interaction_config(keyword() | map()) :: {:ok, map()} | {:error, map()}
  def verify_core_interaction_config(options \\ []) do
    options = Map.new(options)
    configured_apps = Map.get(options, :configured_apps, configured_runtime_apps())

    configured_env =
      options
      |> Map.get(:configured_env, Application.get_all_env(:ourocode))
      |> NetworkListenerConfig.normalize_entries()

    context_config =
      options
      |> Map.get(:context_config, %{})
      |> NetworkListenerConfig.normalize_entries()

    forbidden_dependency_apps = NetworkListenerBoundary.forbidden_dependency_apps(configured_apps)

    endpoint_requirements =
      configured_env
      |> Kernel.++(context_config)
      |> NetworkListenerConfig.core_endpoint_requirements()

    if forbidden_dependency_apps == [] and endpoint_requirements == [] do
      {:ok,
       %{
         status: :terminal_core_endpoint_free,
         core_interaction_requires_endpoint?: false,
         forbidden_server_dependency_apps: [],
         configured_core_endpoint_requirements: [],
         allowed_client_transport_apps:
           NetworkListenerBoundary.allowed_client_transport_apps(configured_apps),
         checked_at_ms: System.monotonic_time(:millisecond)
       }}
    else
      {:error,
       %{
         status: :unhealthy,
         healthy?: false,
         reason: :terminal_core_endpoint_dependency_configured,
         core_interaction_requires_endpoint?: true,
         forbidden_server_dependency_apps: forbidden_dependency_apps,
         configured_core_endpoint_requirements: endpoint_requirements
       }}
    end
  end

  @doc """
  Files that define the terminal startup/runtime boundary.
  """
  @spec startup_source_files() :: [String.t()]
  def startup_source_files, do: @startup_source_files

  defp default_listener_snapshot do
    %{
      started_applications:
        Enum.map(Application.started_applications(), fn {app, _, _} -> app end),
      registered_processes: Process.registered()
    }
  end

  defp configured_runtime_apps do
    :ourocode
    |> Application.spec(:applications)
    |> List.wrap()
  end

  defp report(started_listener_apps, registered_listener_processes, startup_source_listener_calls) do
    %{
      status: :terminal_listener_free,
      listener_protocols_forbidden: NetworkListenerBoundary.listener_protocols(),
      started_listener_apps: started_listener_apps,
      registered_listener_processes: registered_listener_processes,
      startup_source_listener_calls: startup_source_listener_calls,
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end
end
