defmodule Ourocode.Plugin.ConfigLoaderFields do
  @moduledoc """
  Parses optional loader-only and metadata fields from plugin config entries.
  """

  @metadata_key_pattern ~r/^[A-Za-z0-9_.-]+$/

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), non_neg_integer()) :: {:ok, map()} | schema_error()
  def parse(plugin, index) when is_map(plugin) do
    with {:ok, expected_checksum} <- optional_string_field(plugin, "expected_checksum", index),
         {:ok, manifest_filename} <- optional_string_field(plugin, "manifest_filename", index),
         {:ok, metadata} <- optional_map_field(plugin, "metadata", index),
         :ok <- validate_metadata(metadata || %{}, index),
         {:ok, config} <- optional_map_field(plugin, "config", index) do
      fields =
        %{}
        |> maybe_put(:expected_checksum, expected_checksum)
        |> maybe_put(:manifest_filename, manifest_filename)
        |> maybe_put(:metadata, metadata || %{})
        |> maybe_put(:config, config)

      {:ok, fields}
    end
  end

  defp optional_string_field(plugin, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be a non-empty string")
    end
  end

  defp optional_map_field(plugin, key, index) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be an object")
    end
  end

  defp validate_metadata(metadata, index) do
    Enum.reduce_while(metadata, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) or key == "" or not Regex.match?(@metadata_key_pattern, key) ->
          {:halt, schema_error("plugins[#{index}].metadata keys must be non-empty strings")}

        valid_metadata_value?(value) ->
          {:cont, :ok}

        true ->
          {:halt,
           schema_error(
             "plugins[#{index}].metadata.#{key} must be a string, number, boolean, null, or list of strings"
           )}
      end
    end)
  end

  defp valid_metadata_value?(value) when is_binary(value), do: true
  defp valid_metadata_value?(value) when is_boolean(value), do: true
  defp valid_metadata_value?(value) when is_number(value), do: true
  defp valid_metadata_value?(nil), do: true

  defp valid_metadata_value?(values) when is_list(values) do
    Enum.all?(values, &(is_binary(&1) and &1 != ""))
  end

  defp valid_metadata_value?(_value), do: false

  defp maybe_put(fields, _key, nil), do: fields
  defp maybe_put(fields, key, value), do: Map.put(fields, key, value)

  defp schema_error(message), do: {:error, {:invalid_plugin_config_schema, message}}
end
