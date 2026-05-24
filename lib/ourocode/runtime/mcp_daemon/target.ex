defmodule Ourocode.Runtime.McpDaemon.Target do
  @moduledoc """
  Pure target-selection policy for the Ouroboros MCP daemon.
  """

  @default_url "http://127.0.0.1:4000/mcp"

  @type decision ::
          :disabled
          | {:external, String.t()}
          | {:spawn, String.t(), :inet.port_number(), String.t(), boolean()}

  @spec default_url() :: String.t()
  def default_url, do: @default_url

  @spec decide(
          boolean(),
          String.t() | nil,
          (String.t(), :inet.port_number() -> boolean()),
          (-> :inet.port_number())
        ) ::
          decision()
  def decide(disabled?, explicit_url, port_open?, free_port)
      when is_boolean(disabled?) and is_function(port_open?, 2) and is_function(free_port, 0) do
    cond do
      disabled? ->
        :disabled

      is_binary(explicit_url) ->
        {host, port} = host_port(explicit_url)

        if port_open?.(host, port),
          do: {:external, explicit_url},
          else: {:spawn, host, port, explicit_url, true}

      true ->
        host = "127.0.0.1"
        port = free_port.()
        {:spawn, host, port, url(host, port), false}
    end
  end

  @spec host_port(String.t()) :: {String.t(), :inet.port_number()}
  def host_port(url) when is_binary(url) do
    uri = URI.parse(url)
    {uri.host || "127.0.0.1", uri.port || 4000}
  end

  @spec url(String.t(), :inet.port_number()) :: String.t()
  def url(host, port) when is_binary(host) and is_integer(port) do
    "http://#{host}:#{port}/mcp"
  end
end
