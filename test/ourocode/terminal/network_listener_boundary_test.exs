defmodule Ourocode.Terminal.NetworkListenerBoundaryTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.NetworkListenerBoundary

  test "detects forbidden started listener applications" do
    assert NetworkListenerBoundary.started_listener_apps(%{
             started_applications: [:logger, :inets, :bandit, :phoenix_live_view]
           }) == [
             %{application: :bandit, protocol: :http},
             %{application: :phoenix_live_view, protocol: :websocket}
           ]
  end

  test "detects forbidden registered listener processes while allowing inets client supervisor" do
    assert NetworkListenerBoundary.registered_listener_processes(%{
             registered_processes: [:httpd_sup, :httpd_instance_sup, :sse_listener]
           }) == [
             %{registered_name: :httpd_instance_sup, protocol: :http},
             %{registered_name: :sse_listener, protocol: :sse}
           ]
  end

  test "detects source listener calls by fragment groups" do
    source_path =
      tmp_file!("network-boundary-source", """
      defmodule Listener do
        def http, do: :ranch.start_listener(:my_listener, :ranch_tcp, [], :cowboy_clear, [])
        def sse, do: "text/event-stream" <> " listen"
      end
      """)

    calls = NetworkListenerBoundary.startup_source_listener_calls([source_path])

    assert %{file: source_path, protocol: :http, pattern: ":ranch.start_listener"} in calls
    assert %{file: source_path, protocol: :sse, pattern: "text/event-stream.listen"} in calls
  end

  test "classifies configured dependency apps and allowed client transports" do
    configured_apps = [:kernel, :inets, :ssl, :bandit, :ranch]

    assert NetworkListenerBoundary.allowed_client_transport_apps(configured_apps) == [
             :inets,
             :ssl
           ]

    assert NetworkListenerBoundary.forbidden_dependency_apps(configured_apps) == [
             %{application: :bandit, protocol: :http},
             %{application: :ranch, protocol: :http}
           ]
  end

  defp tmp_file!(name, contents) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.ex")

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
