defmodule Ourocode.Terminal.NetworkListenerConfigTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.NetworkListenerConfig

  test "normalizes nested keyword and map config entries" do
    assert [
             %{path: [:terminal, :http, :port], value: 4000},
             %{path: [:runtime, "sse_endpoint"], value: "http://127.0.0.1/events"}
           ] =
             NetworkListenerConfig.normalize_entries(
               terminal: [http: [port: 4000]],
               runtime: %{"sse_endpoint" => "http://127.0.0.1/events"}
             )
  end

  test "detects core endpoint requirements and classifies protocols" do
    entries =
      NetworkListenerConfig.normalize_entries(%{
        terminal_http_endpoint: " http://127.0.0.1:4000 ",
        terminal_websocket_port: 4001,
        runtime_sse_listener: true,
        plugin_endpoint: "http://remote.example"
      })

    assert [
             %{
               path: "runtime_sse_listener",
               protocol: :sse,
               value_summary: "true"
             },
             %{
               path: "terminal_http_endpoint",
               protocol: :http,
               value_summary: "http://127.0.0.1:4000"
             },
             %{
               path: "terminal_websocket_port",
               protocol: :websocket,
               value_summary: "4001"
             }
           ] =
             entries
             |> NetworkListenerConfig.core_endpoint_requirements()
             |> Enum.sort_by(& &1.path)
  end

  test "ignores empty or non-core endpoint-looking entries" do
    entries =
      NetworkListenerConfig.normalize_entries(%{
        terminal_http_endpoint: " ",
        prompt_port: 0,
        plugin_endpoint: "http://remote.example",
        unrelated: true
      })

    assert NetworkListenerConfig.core_endpoint_requirements(entries) == []
  end
end
