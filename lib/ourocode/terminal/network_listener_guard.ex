defmodule Ourocode.Terminal.NetworkListenerGuard do
  @moduledoc """
  Startup guard for terminal-only listener boundaries.

  Terminal bootstrap may initialize client-side MCP transports, but it must not
  create or bind HTTP, WebSocket, or SSE listener surfaces. This guard verifies
  the startup source boundary and the live OTP process/application snapshot.
  """

  @listener_protocols [:http, :websocket, :sse]

  @forbidden_started_apps %{
    bandit: :http,
    cowboy: :http,
    cowboy_websocket: :websocket,
    phoenix: :http,
    phoenix_live_view: :websocket,
    plug_cowboy: :http,
    ranch: :http
  }

  # NOTE: `:httpd_sup` is intentionally NOT forbidden. The inets application
  # registers it as an internal umbrella supervisor whenever `:inets.start/0`
  # runs, including pure `:httpc` *client* usage by MCP HTTP/SSE transports,
  # which the seed explicitly allows. A bound HTTP *server* surfaces instead as
  # a running `:httpd_instance_sup`, which remains forbidden below.
  @forbidden_registered_names %{
    bandit_sup: :http,
    cowboy_sup: :http,
    ranch_sup: :http,
    httpd_instance_sup: :http,
    phoenix_endpoint: :http,
    websocket_listener: :websocket,
    sse_listener: :sse
  }

  @allowed_client_transport_apps MapSet.new([:inets, :ssl])

  @core_endpoint_tokens MapSet.new([
                          "core",
                          "input",
                          "input_loop",
                          "interactive",
                          "prompt",
                          "runtime",
                          "terminal",
                          "terminal_ui",
                          "tui",
                          "ui"
                        ])

  @endpoint_requirement_tokens MapSet.new([
                                 "endpoint",
                                 "http",
                                 "https",
                                 "listen",
                                 "listener",
                                 "local_http",
                                 "port",
                                 "server",
                                 "sse",
                                 "websocket",
                                 "web_socket",
                                 "ws",
                                 "wss"
                               ])

  @forbidden_source_calls [
    {:http, [":gen_tcp", "listen"]},
    {:http, [":ssl", "listen"]},
    {:http, ["Bandit", "start_link"]},
    {:http, ["Plug.Cowboy", "http"]},
    {:http, ["Plug.Cowboy", "https"]},
    {:http, ["Phoenix.Endpoint", "server"]},
    {:http, [":cowboy", "start_clear"]},
    {:http, [":cowboy", "start_tls"]},
    {:http, [":ranch", "start_listener"]},
    {:http, [":inets", "start", ":httpd"]},
    {:http, [":httpd", "start"]},
    {:websocket, ["websocket", "listen"]},
    {:websocket, ["WebSockAdapter", "start_link"]},
    {:sse, ["sse", "listen"]},
    {:sse, ["text/event-stream", "listen"]}
  ]

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

    started_listener_apps = started_listener_apps(snapshot)
    registered_listener_processes = registered_listener_processes(snapshot)
    startup_source_listener_calls = startup_source_listener_calls(source_files)

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
         listener_protocols_forbidden: @listener_protocols,
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
      |> normalize_config_entries()

    context_config =
      options
      |> Map.get(:context_config, %{})
      |> normalize_config_entries()

    forbidden_dependency_apps = forbidden_dependency_apps(configured_apps)

    endpoint_requirements =
      configured_env
      |> Kernel.++(context_config)
      |> Enum.flat_map(&core_endpoint_requirements/1)

    if forbidden_dependency_apps == [] and endpoint_requirements == [] do
      {:ok,
       %{
         status: :terminal_core_endpoint_free,
         core_interaction_requires_endpoint?: false,
         forbidden_server_dependency_apps: [],
         configured_core_endpoint_requirements: [],
         allowed_client_transport_apps: allowed_client_transport_apps(configured_apps),
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

  defp forbidden_dependency_apps(configured_apps) do
    configured_apps
    |> Enum.reject(&MapSet.member?(@allowed_client_transport_apps, &1))
    |> Enum.filter(&Map.has_key?(@forbidden_started_apps, &1))
    |> Enum.map(fn app ->
      %{application: app, protocol: Map.fetch!(@forbidden_started_apps, app)}
    end)
  end

  defp allowed_client_transport_apps(configured_apps) do
    configured_apps
    |> Enum.filter(&MapSet.member?(@allowed_client_transport_apps, &1))
    |> Enum.sort()
  end

  defp normalize_config_entries(entries) when is_list(entries) do
    Enum.flat_map(entries, fn {key, value} -> flatten_config_entry([key], value) end)
  end

  defp normalize_config_entries(entries) when is_map(entries) do
    Enum.flat_map(entries, fn {key, value} -> flatten_config_entry([key], value) end)
  end

  defp normalize_config_entries(_entries), do: []

  defp flatten_config_entry(path, value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested_value} ->
      flatten_config_entry(path ++ [key], nested_value)
    end)
  end

  defp flatten_config_entry(path, value) when is_list(value) and not is_binary(value) do
    if Keyword.keyword?(value) do
      Enum.flat_map(value, fn {key, nested_value} ->
        flatten_config_entry(path ++ [key], nested_value)
      end)
    else
      [%{path: path, value: value}]
    end
  end

  defp flatten_config_entry(path, value), do: [%{path: path, value: value}]

  defp core_endpoint_requirements(%{path: path, value: value}) do
    tokens = path_tokens(path)

    if core_endpoint_path?(tokens) and endpoint_requirement_value?(value) do
      [
        %{
          path: Enum.map_join(path, ".", &to_string/1),
          protocol: endpoint_protocol(tokens, value),
          value_summary: endpoint_value_summary(value)
        }
      ]
    else
      []
    end
  end

  defp path_tokens(path) do
    path
    |> Enum.flat_map(fn segment ->
      segment
      |> to_string()
      |> String.downcase()
      |> String.split([".", "-", "_"], trim: true)
    end)
    |> MapSet.new()
  end

  defp core_endpoint_path?(tokens) do
    intersects?(tokens, @core_endpoint_tokens) and
      intersects?(tokens, @endpoint_requirement_tokens)
  end

  defp endpoint_requirement_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp endpoint_requirement_value?(value) when is_integer(value), do: value > 0
  defp endpoint_requirement_value?(true), do: true
  defp endpoint_requirement_value?(_value), do: false

  defp endpoint_protocol(tokens, value) do
    cond do
      MapSet.member?(tokens, "websocket") or MapSet.member?(tokens, "web_socket") or
        MapSet.member?(tokens, "ws") or endpoint_value_protocol?(value, ["ws://", "wss://"]) ->
        :websocket

      MapSet.member?(tokens, "sse") ->
        :sse

      true ->
        :http
    end
  end

  defp endpoint_value_protocol?(value, prefixes) when is_binary(value) do
    value = String.downcase(String.trim(value))
    Enum.any?(prefixes, &String.starts_with?(value, &1))
  end

  defp endpoint_value_protocol?(_value, _prefixes), do: false

  defp endpoint_value_summary(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp endpoint_value_summary(value), do: inspect(value)

  defp intersects?(left, right) do
    Enum.any?(left, &MapSet.member?(right, &1))
  end

  defp started_listener_apps(snapshot) do
    snapshot
    |> Map.get(:started_applications, [])
    |> Enum.filter(&Map.has_key?(@forbidden_started_apps, &1))
    |> Enum.map(fn app ->
      %{application: app, protocol: Map.fetch!(@forbidden_started_apps, app)}
    end)
  end

  defp registered_listener_processes(snapshot) do
    snapshot
    |> Map.get(:registered_processes, [])
    |> Enum.filter(&Map.has_key?(@forbidden_registered_names, &1))
    |> Enum.map(fn name ->
      %{registered_name: name, protocol: Map.fetch!(@forbidden_registered_names, name)}
    end)
  end

  defp startup_source_listener_calls(source_files) do
    source_files
    |> Enum.flat_map(&listener_calls_in_file/1)
  end

  defp listener_calls_in_file(path) do
    case File.read(path) do
      {:ok, source} ->
        @forbidden_source_calls
        |> Enum.filter(fn {_protocol, fragments} ->
          source_contains_fragments?(source, fragments)
        end)
        |> Enum.map(fn {protocol, fragments} ->
          %{file: path, protocol: protocol, pattern: Enum.join(fragments, ".")}
        end)

      {:error, _reason} ->
        []
    end
  end

  defp source_contains_fragments?(source, fragments) do
    Enum.all?(fragments, &String.contains?(source, &1))
  end

  defp report(started_listener_apps, registered_listener_processes, startup_source_listener_calls) do
    %{
      status: :terminal_listener_free,
      listener_protocols_forbidden: @listener_protocols,
      started_listener_apps: started_listener_apps,
      registered_listener_processes: registered_listener_processes,
      startup_source_listener_calls: startup_source_listener_calls,
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end
end
