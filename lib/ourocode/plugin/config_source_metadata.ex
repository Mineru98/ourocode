defmodule Ourocode.Plugin.ConfigSourceMetadata do
  @moduledoc """
  Source metadata parsing and default propagation for plugin config entries.
  """

  alias Ourocode.Plugin.ConfigPackageIdentity

  @type schema_error :: {:error, {:invalid_plugin_config_schema, String.t()}}

  @spec parse(map(), non_neg_integer()) :: {:ok, map() | nil} | schema_error()
  def parse(plugin, index) when is_map(plugin) do
    case Map.fetch(plugin, "source_metadata") do
      {:ok, source_metadata} when is_map(source_metadata) ->
        with :ok <- validate_optional_string(source_metadata, "id", index),
             :ok <- validate_optional_string(source_metadata, "source", index),
             :ok <- validate_optional_map(source_metadata, "provenance", index),
             :ok <- validate_optional_map(source_metadata, "trust_policy", index),
             :ok <- validate_optional_map(source_metadata, "package_identity", index) do
          {:ok, source_metadata}
        end

      :error ->
        {:ok, nil}

      _invalid ->
        schema_error("plugins[#{index}].source_metadata must be an object")
    end
  end

  @spec validate_id(map() | nil, String.t(), non_neg_integer()) :: :ok | schema_error()
  def validate_id(nil, _id, _index), do: :ok

  def validate_id(source_metadata, id, index) when is_map(source_metadata) do
    case Map.get(source_metadata, "id") do
      nil ->
        :ok

      ^id ->
        :ok

      source_metadata_id ->
        schema_error(
          "plugins[#{index}].source_metadata.id must match identity.id: #{source_metadata_id}"
        )
    end
  end

  @spec apply_defaults(map(), map() | nil, non_neg_integer()) :: {:ok, map()} | schema_error()
  def apply_defaults(plugin, nil, _index), do: {:ok, plugin}

  def apply_defaults(plugin, source_metadata, index)
      when is_map(plugin) and is_map(source_metadata) do
    with {:ok, plugin} <- put_default(plugin, source_metadata, "source", index),
         {:ok, plugin} <- put_default(plugin, source_metadata, "provenance", index),
         {:ok, plugin} <- put_default(plugin, source_metadata, "trust_policy", index),
         {:ok, plugin} <- put_package_default(plugin, source_metadata) do
      {:ok, plugin}
    end
  end

  defp validate_optional_string(nil, _key, _index), do: :ok

  defp validate_optional_string(source_metadata, key, index) do
    case Map.fetch(source_metadata, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        :ok

      :error ->
        :ok

      _invalid ->
        schema_error("plugins[#{index}].source_metadata.#{key} must be a non-empty string")
    end
  end

  defp validate_optional_map(nil, _key, _index), do: :ok

  defp validate_optional_map(source_metadata, key, index) do
    case Map.fetch(source_metadata, key) do
      {:ok, value} when is_map(value) ->
        :ok

      :error ->
        :ok

      _invalid ->
        schema_error("plugins[#{index}].source_metadata.#{key} must be an object")
    end
  end

  defp put_default(plugin, source_metadata, key, index) do
    case {Map.fetch(plugin, key), Map.fetch(source_metadata, key)} do
      {:error, {:ok, value}} ->
        {:ok, Map.put(plugin, key, value)}

      {{:ok, value}, {:ok, value}} ->
        {:ok, plugin}

      {{:ok, _plugin_value}, {:ok, _source_metadata_value}} ->
        schema_error("plugins[#{index}].source_metadata.#{key} must match #{key}")

      {_plugin_field, _source_metadata_field} ->
        {:ok, plugin}
    end
  end

  defp put_package_default(plugin, source_metadata) do
    case {Map.fetch(plugin, "package"), Map.fetch(source_metadata, "package_identity")} do
      {:error, {:ok, package_identity}} ->
        {:ok,
         Map.put(plugin, "package", ConfigPackageIdentity.to_package_config(package_identity))}

      _existing_or_missing ->
        {:ok, plugin}
    end
  end

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end
end
