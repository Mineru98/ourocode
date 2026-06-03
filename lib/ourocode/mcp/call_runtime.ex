defmodule Ourocode.MCP.CallRuntime do
  @moduledoc """
  Executes MCP tool calls as first-class parent calls.

  Transports deal in JSON-RPC payloads. This module gives the rest of ourocode a
  domain API: call an MCP tool by name, attach a stable parent call id, and let
  the transport stream lifecycle events for panes and journal replay.
  """

  alias Ourocode.MCP.Transport.StreamableHTTP

  @type option ::
          {:url, String.t()}
          | {:parent_call_id, String.t()}
          | {:runtime_source, String.t()}
          | {:subscriber, pid()}
          | {:journal_path, Path.t()}
          | {:headers, [{String.t(), String.t()}]}
          | {:timeout, pos_integer()}

  @type execution_option ::
          {:request_id, String.t()}
          | {:execute_parent_call, (keyword(), map() -> term())}

  @doc """
  Executes one MCP `tools/call` request through the configured parent-call transport.
  """
  @spec execute_tool_call([option()], String.t(), map() | nil, [execution_option()]) :: term()
  def execute_tool_call(options, tool_name, arguments \\ %{}, execution_opts \\ [])
      when is_list(options) and is_binary(tool_name) and is_list(execution_opts) do
    parent_call_id = parent_call_id(options, tool_name)

    options =
      options
      |> Keyword.put(:parent_call_id, parent_call_id)
      |> Keyword.put_new(:runtime_source, "ouroboros")

    request = tools_call_request(tool_name, arguments, request_id(parent_call_id, execution_opts))

    execute_parent_call =
      Keyword.get(execution_opts, :execute_parent_call, &StreamableHTTP.execute_parent_call/2)

    execute_parent_call.(options, request)
  end

  @doc """
  Builds the JSON-RPC request sent to MCP servers for `tools/call`.
  """
  @spec tools_call_request(String.t(), map() | nil, String.t()) :: map()
  def tools_call_request(tool_name, arguments \\ %{}, request_id \\ "call-1")
      when is_binary(tool_name) and is_binary(request_id) do
    %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => "tools/call",
      "params" => %{
        "name" => tool_name,
        "arguments" => normalize_arguments(arguments)
      }
    }
  end

  @doc """
  Returns the generated parent call id for a tool call option set.
  """
  @spec parent_call_id(keyword(), String.t()) :: String.t()
  def parent_call_id(options, tool_name) when is_list(options) and is_binary(tool_name) do
    case Keyword.get(options, :parent_call_id) do
      value when is_binary(value) and value != "" -> value
      _value -> "parent-mcp-tool-" <> slug(tool_name)
    end
  end

  defp request_id(parent_call_id, execution_opts) do
    case Keyword.get(execution_opts, :request_id) do
      value when is_binary(value) and value != "" -> value
      _value -> "call-" <> parent_call_id
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments), do: arguments
  defp normalize_arguments(nil), do: %{}

  defp slug(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      slug -> slug
    end
  end
end
