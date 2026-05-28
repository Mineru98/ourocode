defmodule Ourocode.Terminal.ApplicationTest do
  use ExUnit.Case, async: false

  alias Ourocode.Terminal.Application

  test "terminal bootstrap attaches runtime services to dashboard startup state" do
    project_dir = File.cwd!()

    assert {:ok, result} =
             Application.bootstrap(%{
               project_dir: project_dir,
               cwd: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-dashboard-test",
               journal_path:
                 Path.join(System.tmp_dir!(), "ourocode-terminal-#{unique_id()}.jsonl")
             })

    on_exit(fn -> Ourocode.Runtime.Application.stop(result.runtime) end)

    assert result.status == :healthy
    assert result.healthy? == true
    assert result.context.terminal_native? == true
    assert result.context.bootstrap_module == Ourocode.Terminal.Application
    assert result.context.browser_runtime_guard.status == :terminal_only
    assert result.context.browser_runtime_guard.browser_runtime_allowed? == false
    assert result.context.browser_runtime_guard.forbidden_otp_apps == []
    assert result.context.core_interaction_config_guard.status == :terminal_core_endpoint_free

    assert result.context.core_interaction_config_guard.core_interaction_requires_endpoint? ==
             false

    assert result.context.core_interaction_config_guard.configured_core_endpoint_requirements ==
             []

    assert result.context.core_interaction_config_guard.forbidden_server_dependency_apps == []
    assert result.core_interaction_config_guard.status == :terminal_core_endpoint_free
    assert result.context.network_listener_guard_before.status == :terminal_listener_free
    assert result.context.network_listener_guard_after.status == :terminal_listener_free

    assert result.context.network_listener_guard_after.listener_protocols_forbidden == [
             :http,
             :websocket,
             :sse
           ]

    assert result.context.network_listener_guard_after.started_listener_apps == []
    assert result.context.network_listener_guard_after.registered_listener_processes == []
    assert result.context.network_listener_guard_after.startup_source_listener_calls == []
    assert result.network_listener_guard_after.status == :terminal_listener_free
    assert result.context.root_ui_module == Ourocode.Terminal.RootUI
    assert result.context.ui_surface == :terminal
    assert result.root_ui_module == Ourocode.Terminal.RootUI
    assert result.ui_surface == :terminal
    assert result.context.runtime.session_id == "terminal-dashboard-test"
    assert result.runtime.session_id == "terminal-dashboard-test"
    assert result.runtime.status == :ready
    assert result.terminal_renderer == Ourocode.Terminal.ShellRenderer
    assert result.initial_terminal_frame_renderer == Ourocode.Terminal.ShellRenderer

    assert result.initial_terminal_frame ==
             Ourocode.Terminal.ShellRenderer.render_initial_frame(result)

    assert result.initial_terminal_frame =~ "ourocode agent"
    assert result.initial_terminal_frame =~ "Start here:"
    assert result.initial_terminal_frame =~ "Prompt: Describe a task for a new session"
    refute result.initial_terminal_frame =~ "session=terminal-dashboard-test"
    refute result.initial_terminal_frame =~ "region="
    assert Process.alive?(result.runtime.supervisor_pid)
    assert result.runtime.service_statuses.transport_supervisor == :ready
    assert result.runtime.service_statuses.command_registry == :ready
    assert result.runtime.service_statuses.wonder_tool == :ready
  end

  test "terminal bootstrap boundary rejects browser UI runtime dependencies" do
    assert {:ok, guard} = Ourocode.Terminal.BrowserRuntimeGuard.verify_startup_boundary()

    assert guard.status == :terminal_only
    assert guard.browser_runtime_allowed? == false
    assert guard.forbidden_otp_apps == []

    terminal_startup_files = [
      "lib/ourocode/cli.ex",
      "lib/ourocode/terminal/application.ex",
      "lib/ourocode/terminal/root_ui.ex",
      "lib/ourocode/terminal/event_loop.ex",
      "lib/ourocode/terminal/shell_renderer.ex"
    ]

    startup_source =
      terminal_startup_files
      |> Enum.map(&File.read!/1)
      |> Enum.join("\n")

    forbidden_commands =
      Enum.filter(
        Ourocode.Terminal.BrowserRuntimeGuard.forbidden_process_commands(),
        fn command ->
          startup_source =~ "{:spawn_executable, \"#{command}\"}" or
            startup_source =~ "System.cmd(\"#{command}\"" or
            startup_source =~ "Port.open({:spawn, \"#{command}"
        end
      )

    assert forbidden_commands == []
    refute startup_source =~ "Phoenix.Endpoint"
    refute startup_source =~ "LiveView"
    refute startup_source =~ "WebView"
  end

  test "terminal bootstrap boundary rejects HTTP WebSocket and SSE listener surfaces" do
    alias Ourocode.Terminal.NetworkListenerGuard

    assert {:error, http_result} =
             NetworkListenerGuard.verify_startup_boundary(%{
               listener_snapshot: %{
                 started_applications: [:logger, :bandit],
                 registered_processes: []
               },
               source_files: []
             })

    assert http_result.reason == :terminal_startup_listener_boundary_violation
    assert [%{application: :bandit, protocol: :http}] = http_result.started_listener_apps

    assert {:error, ws_result} =
             NetworkListenerGuard.verify_startup_boundary(%{
               listener_snapshot: %{
                 started_applications: [],
                 registered_processes: [:websocket_listener]
               },
               source_files: []
             })

    assert [%{registered_name: :websocket_listener, protocol: :websocket}] =
             ws_result.registered_listener_processes

    source_path = Path.join(System.tmp_dir!(), "ourocode-sse-listener-#{unique_id()}.ex")
    File.write!(source_path, "def start, do: {:ok, :sse} # listen\n")

    assert {:error, sse_result} =
             NetworkListenerGuard.verify_startup_boundary(%{
               listener_snapshot: %{started_applications: [], registered_processes: []},
               source_files: [source_path]
             })

    assert [%{file: ^source_path, protocol: :sse}] = sse_result.startup_source_listener_calls
  end

  test "terminal core interaction config validation does not require local endpoint config" do
    alias Ourocode.Terminal.NetworkListenerGuard

    assert {:ok, report} =
             NetworkListenerGuard.verify_core_interaction_config(%{
               configured_apps: [:kernel, :stdlib, :logger, :inets, :ssl],
               configured_env: [],
               context_config: Ourocode.Config.defaults()
             })

    assert report.status == :terminal_core_endpoint_free
    assert report.core_interaction_requires_endpoint? == false
    assert report.configured_core_endpoint_requirements == []
    assert report.forbidden_server_dependency_apps == []
    assert report.allowed_client_transport_apps == [:inets, :ssl]

    assert {:error, result} =
             NetworkListenerGuard.verify_core_interaction_config(%{
               configured_apps: [:kernel, :bandit],
               configured_env: [terminal_http_endpoint: "http://127.0.0.1:4000"],
               context_config: %{terminal_websocket_port: 4001}
             })

    assert result.reason == :terminal_core_endpoint_dependency_configured
    assert result.core_interaction_requires_endpoint? == true
    assert [%{application: :bandit, protocol: :http}] = result.forbidden_server_dependency_apps

    assert [
             %{path: "terminal_http_endpoint", protocol: :http},
             %{path: "terminal_websocket_port", protocol: :websocket}
           ] = Enum.sort_by(result.configured_core_endpoint_requirements, & &1.path)
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end
end
