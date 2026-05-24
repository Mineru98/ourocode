defmodule Ourocode.Plugin.ConfigFields do
  @moduledoc """
  Common field readers for plugin config schema parsing.
  """

  alias Ourocode.Plugin.ConfigSettings

  @valid_sources MapSet.new(["official", "third_party", "local", "user"])

  @spec required_string(map(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def required_string(plugin, key, index) when is_map(plugin) and is_binary(key) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _missing_or_invalid ->
        schema_error("plugins[#{index}].#{key} must be a non-empty string")
    end
  end

  @spec optional_string(map(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def optional_string(plugin, key, default, index) when is_map(plugin) and is_binary(key) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      :error ->
        {:ok, default}

      _invalid ->
        schema_error("plugins[#{index}].#{key} must be a non-empty string")
    end
  end

  @spec optional_boolean(map(), String.t(), boolean(), non_neg_integer()) ::
          {:ok, boolean()} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def optional_boolean(plugin, key, default, index) when is_map(plugin) and is_binary(key) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:ok, default}
      _invalid -> schema_error("plugins[#{index}].#{key} must be a boolean")
    end
  end

  @spec optional_map(map(), String.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def optional_map(plugin, key, default, index) when is_map(plugin) and is_binary(key) do
    case Map.fetch(plugin, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      :error -> {:ok, default}
      _invalid -> schema_error("plugins[#{index}].#{key} must be an object")
    end
  end

  @spec validate_source(String.t(), non_neg_integer()) ::
          :ok | {:error, {:invalid_plugin_config_schema, String.t()}}
  def validate_source(source, index) do
    if MapSet.member?(@valid_sources, source) do
      :ok
    else
      schema_error("plugins[#{index}].source is unsupported")
    end
  end

  @spec parse_settings(map(), non_neg_integer()) ::
          {:ok, map()} | {:error, {:invalid_plugin_config_schema, String.t()}}
  def parse_settings(plugin, index) when is_map(plugin) do
    case Map.fetch(plugin, "settings") do
      {:ok, settings} when is_map(settings) ->
        ConfigSettings.normalize(settings, "plugins[#{index}].settings")

      :error ->
        {:ok, %{}}

      _invalid ->
        schema_error("plugins[#{index}].settings must be an object")
    end
  end

  defp schema_error(message) do
    {:error, {:invalid_plugin_config_schema, message}}
  end
end
