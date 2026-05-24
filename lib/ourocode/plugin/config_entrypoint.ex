defmodule Ourocode.Plugin.ConfigEntrypoint do
  @moduledoc """
  Parses and validates plugin entrypoint declarations.
  """

  alias Ourocode.Plugin.ConfigValidation

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), non_neg_integer()) :: {:ok, map()} | schema_error()
  def parse(plugin, index) when is_map(plugin) do
    case Map.fetch(plugin, "entrypoint") do
      {:ok, entrypoint} when is_map(entrypoint) ->
        with {:ok, type} <- required_nested_string(entrypoint, "entrypoint", "type", index),
             :ok <- validate_target(entrypoint, type, index) do
          {:ok, entrypoint}
        end

      _missing_or_invalid ->
        schema_error("plugins[#{index}].entrypoint must be an object")
    end
  end

  defp validate_target(entrypoint, "elixir_module", index) do
    case required_nested_string(entrypoint, "entrypoint", "module", index) do
      {:ok, module} -> ConfigValidation.validate_entrypoint_module(module, index)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target(entrypoint, "executable", index) do
    case required_nested_string(entrypoint, "entrypoint", "command", index) do
      {:ok, command} -> ConfigValidation.validate_entrypoint_command(command, index)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target(entrypoint, "manifest", index) do
    case required_nested_string(entrypoint, "entrypoint", "path", index) do
      {:ok, path} -> ConfigValidation.validate_entrypoint_path(path, "entrypoint.path", index)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_target(_entrypoint, type, index) do
    schema_error("plugins[#{index}].entrypoint.type is unsupported: #{type}")
  end

  defp required_nested_string(plugin, parent_key, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _missing_or_invalid ->
        schema_error("plugins[#{index}].#{parent_key}.#{key} must be a non-empty string")
    end
  end

  defp schema_error(message), do: {:error, {:invalid_plugin_config_schema, message}}
end
