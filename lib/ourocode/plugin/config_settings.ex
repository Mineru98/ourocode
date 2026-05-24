defmodule Ourocode.Plugin.ConfigSettings do
  @moduledoc """
  Normalizes plugin settings into JSON-safe string-keyed maps.
  """

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec normalize(map(), String.t()) :: {:ok, map()} | schema_error()
  def normalize(settings, path) when is_map(settings) and is_binary(path) do
    settings
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        not valid_setting_key?(key) ->
          {:halt, schema_error("#{path} keys must be non-empty strings")}

        Map.has_key?(acc, key) ->
          {:halt, schema_error("#{path}.#{key} is duplicated after normalization")}

        true ->
          case normalize_value(value, "#{path}.#{key}") do
            {:ok, normalized_value} -> {:cont, {:ok, Map.put(acc, key, normalized_value)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  def normalize(_settings, path) when is_binary(path) do
    schema_error("#{path} must be an object")
  end

  defp normalize_value(value, _path) when is_binary(value), do: {:ok, value}
  defp normalize_value(value, _path) when is_boolean(value), do: {:ok, value}
  defp normalize_value(value, _path) when is_number(value), do: {:ok, value}
  defp normalize_value(nil, _path), do: {:ok, nil}

  defp normalize_value(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case normalize_value(value, "#{path}[#{index}]") do
        {:ok, normalized_value} -> {:cont, {:ok, [normalized_value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_values} -> {:ok, Enum.reverse(normalized_values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_value(value, path) when is_map(value) do
    normalize(value, path)
  end

  defp normalize_value(_value, path) do
    schema_error(
      "#{path} must be a JSON-safe setting value: string, number, boolean, null, list, or object"
    )
  end

  defp valid_setting_key?(key) when is_binary(key) and key != "" do
    String.trim(key) == key and not String.contains?(key, ["\0", "\n", "\r"])
  end

  defp valid_setting_key?(_key), do: false

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end
end
