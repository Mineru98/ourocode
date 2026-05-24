defmodule Ourocode.Terminal.NetworkListenerBoundary do
  @moduledoc """
  Pure boundary checks for terminal listener-free startup.
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

  # `:httpd_sup` belongs to inets client usage. A server listener appears as
  # `:httpd_instance_sup`, which remains forbidden.
  @forbidden_registered_names %{
    bandit_sup: :http,
    cowboy_sup: :http,
    ranch_sup: :http,
    httpd_instance_sup: :http,
    phoenix_endpoint: :http,
    websocket_listener: :websocket,
    sse_listener: :sse
  }

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

  @allowed_client_transport_apps MapSet.new([:inets, :ssl])

  @spec listener_protocols() :: [atom()]
  def listener_protocols, do: @listener_protocols

  @spec allowed_client_transport_apps() :: MapSet.t(atom())
  def allowed_client_transport_apps, do: @allowed_client_transport_apps

  @spec started_listener_apps(map()) :: [map()]
  def started_listener_apps(snapshot) do
    snapshot
    |> Map.get(:started_applications, [])
    |> Enum.filter(&Map.has_key?(@forbidden_started_apps, &1))
    |> Enum.map(fn app ->
      %{application: app, protocol: Map.fetch!(@forbidden_started_apps, app)}
    end)
  end

  @spec registered_listener_processes(map()) :: [map()]
  def registered_listener_processes(snapshot) do
    snapshot
    |> Map.get(:registered_processes, [])
    |> Enum.filter(&Map.has_key?(@forbidden_registered_names, &1))
    |> Enum.map(fn name ->
      %{registered_name: name, protocol: Map.fetch!(@forbidden_registered_names, name)}
    end)
  end

  @spec startup_source_listener_calls([Path.t()]) :: [map()]
  def startup_source_listener_calls(source_files) do
    Enum.flat_map(source_files, &listener_calls_in_file/1)
  end

  @spec forbidden_dependency_apps([atom()]) :: [map()]
  def forbidden_dependency_apps(configured_apps) do
    configured_apps
    |> Enum.reject(&MapSet.member?(@allowed_client_transport_apps, &1))
    |> Enum.filter(&Map.has_key?(@forbidden_started_apps, &1))
    |> Enum.map(fn app ->
      %{application: app, protocol: Map.fetch!(@forbidden_started_apps, app)}
    end)
  end

  @spec allowed_client_transport_apps([atom()]) :: [atom()]
  def allowed_client_transport_apps(configured_apps) do
    configured_apps
    |> Enum.filter(&MapSet.member?(@allowed_client_transport_apps, &1))
    |> Enum.sort()
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
end
