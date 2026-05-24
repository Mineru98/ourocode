defmodule Ourocode.Plugin.ConfigValidation do
  @moduledoc """
  Focused validators for plugin configuration schema fields.
  """

  @elixir_module_pattern ~r/^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$/

  @spec validate_entrypoint_command(String.t(), non_neg_integer()) ::
          :ok | {:error, {:invalid_plugin_config_schema, String.t()}}
  def validate_entrypoint_command(command, index) when is_binary(command) do
    cond do
      String.trim(command) != command ->
        schema_error(
          "plugins[#{index}].entrypoint.command must not contain surrounding whitespace"
        )

      String.contains?(command, ["\0", "\n", "\r"]) ->
        schema_error("plugins[#{index}].entrypoint.command must be a single command string")

      String.contains?(command, [" ", "\t"]) ->
        schema_error("plugins[#{index}].entrypoint.command must not include arguments")

      Path.type(command) == :absolute ->
        schema_error("plugins[#{index}].entrypoint.command must be a relative command")

      path_traverses?(command) ->
        schema_error(
          "plugins[#{index}].entrypoint.command must be a relative command inside the plugin"
        )

      true ->
        :ok
    end
  end

  @spec validate_entrypoint_module(String.t(), non_neg_integer()) ::
          :ok | {:error, {:invalid_plugin_config_schema, String.t()}}
  def validate_entrypoint_module(module, index) when is_binary(module) do
    if Regex.match?(@elixir_module_pattern, module) do
      :ok
    else
      schema_error("plugins[#{index}].entrypoint.module must be an Elixir module name")
    end
  end

  @spec validate_entrypoint_path(String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, {:invalid_plugin_config_schema, String.t()}}
  def validate_entrypoint_path(path, label, index) when is_binary(path) and is_binary(label) do
    cond do
      String.trim(path) != path ->
        schema_error("plugins[#{index}].#{label} must not contain surrounding whitespace")

      String.contains?(path, ["\0", "\n", "\r"]) ->
        schema_error("plugins[#{index}].#{label} must be a single relative path")

      Path.type(path) == :absolute or path_traverses?(path) ->
        schema_error("plugins[#{index}].#{label} must be a relative path inside the plugin")

      true ->
        :ok
    end
  end

  @spec path_traverses?(String.t()) :: boolean()
  def path_traverses?(path) when is_binary(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp schema_error(message), do: {:error, {:invalid_plugin_config_schema, message}}
end
