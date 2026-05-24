defmodule Ourocode.Plugin.ConfigTransport do
  @moduledoc """
  Parses plugin MCP transport declarations.
  """

  @valid_transport_types MapSet.new(["stdio", "sse", "streamable_http"])

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), non_neg_integer()) :: {:ok, [map()]} | schema_error()
  def parse(plugin, index) when is_map(plugin) do
    case Map.fetch(plugin, "transports") do
      {:ok, transports} when is_list(transports) ->
        transports
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {transport, transport_index}, {:ok, acc} ->
          case parse_transport(transport, index, transport_index) do
            {:ok, parsed_transport} -> {:cont, {:ok, [parsed_transport | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, parsed_transports} -> {:ok, Enum.reverse(parsed_transports)}
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:ok, []}

      _invalid ->
        schema_error("plugins[#{index}].transports must be a list")
    end
  end

  defp parse_transport(transport, plugin_index, transport_index) when is_map(transport) do
    parent_key = "transports[#{transport_index}]"

    with {:ok, type} <- required_nested_string(transport, parent_key, "type", plugin_index),
         :ok <- validate_transport_type(type, plugin_index, transport_index),
         :ok <- validate_transport_required_fields(transport, type, plugin_index, transport_index) do
      {:ok, transport}
    end
  end

  defp parse_transport(_transport, plugin_index, transport_index) do
    schema_error("plugins[#{plugin_index}].transports[#{transport_index}] must be an object")
  end

  defp validate_transport_type(type, plugin_index, transport_index) do
    if MapSet.member?(@valid_transport_types, type) do
      :ok
    else
      supported_types =
        @valid_transport_types
        |> MapSet.to_list()
        |> Enum.sort()
        |> Enum.join(", ")

      schema_error(
        "plugins[#{plugin_index}].transports[#{transport_index}].type is unsupported: #{type}; supported MCP transports are #{supported_types}"
      )
    end
  end

  defp validate_transport_required_fields(transport, "stdio", plugin_index, transport_index) do
    require_transport_string(transport, "command", plugin_index, transport_index)
  end

  defp validate_transport_required_fields(transport, type, plugin_index, transport_index)
       when type in ["sse", "streamable_http"] do
    require_transport_string(transport, "url", plugin_index, transport_index)
  end

  defp require_transport_string(transport, key, plugin_index, transport_index) do
    case Map.fetch(transport, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      _missing_or_invalid ->
        schema_error(
          "plugins[#{plugin_index}].transports[#{transport_index}].#{key} must be a non-empty string"
        )
    end
  end

  defp required_nested_string(plugin, parent_key, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _missing_or_invalid ->
        schema_error("plugins[#{index}].#{parent_key}.#{key} must be a non-empty string")
    end
  end

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end
end
