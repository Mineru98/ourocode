defmodule Ourocode.Plugin.ConfigPermissions do
  @moduledoc """
  Parses and validates plugin permission declarations.
  """

  @required_fields ["filesystem", "network", "process"]

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), non_neg_integer()) :: {:ok, map()} | schema_error()
  def parse(plugin, index) when is_map(plugin) do
    case Map.fetch(plugin, "permissions") do
      {:ok, permissions} when is_map(permissions) ->
        with :ok <- require_fields(permissions, index),
             :ok <- validate_fields(permissions, index) do
          {:ok, permissions}
        end

      _missing_or_invalid ->
        schema_error("plugins[#{index}].permissions must be an object")
    end
  end

  defp require_fields(permissions, index) do
    case Enum.find(@required_fields, &(not Map.has_key?(permissions, &1))) do
      nil -> :ok
      missing -> schema_error("plugins[#{index}].permissions.#{missing} is required")
    end
  end

  defp validate_fields(permissions, index) do
    Enum.reduce_while(@required_fields, :ok, fn field, :ok ->
      case Map.fetch!(permissions, field) do
        values when is_list(values) ->
          validate_values(values, field, index)

        _invalid ->
          {:halt, invalid_values_error(field, index)}
      end
    end)
  end

  defp validate_values(values, field, index) do
    if Enum.all?(values, &valid_permission_value?/1) do
      {:cont, :ok}
    else
      {:halt, invalid_values_error(field, index)}
    end
  end

  defp invalid_values_error(field, index) do
    schema_error("plugins[#{index}].permissions.#{field} must be a list of non-empty strings")
  end

  defp valid_permission_value?(value) when is_binary(value) and value != "" do
    String.trim(value) == value and not String.contains?(value, ["\0", "\n", "\r"])
  end

  defp valid_permission_value?(_value), do: false

  defp schema_error(message), do: {:error, {:invalid_plugin_config_schema, message}}
end
