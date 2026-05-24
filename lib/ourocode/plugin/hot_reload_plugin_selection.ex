defmodule Ourocode.Plugin.HotReloadPluginSelection do
  @moduledoc """
  Selects configured plugins and derives loader options for hot reload.

  Hot reload state transitions stay in `HotReloadBoundary`; this module keeps
  plugin entry selection rules and loader-only option mapping isolated.
  """

  alias Ourocode.Plugin.ConfigSchema

  @doc """
  Selects a plugin by id, or prefers the first enabled plugin when no id is
  provided.
  """
  @spec select([ConfigSchema.PluginEntry.t()], String.t() | nil) ::
          {:ok, ConfigSchema.PluginEntry.t()}
          | {:error, :plugin_config_empty | {:plugin_not_configured, String.t() | nil}}
  def select([], nil), do: {:error, :plugin_config_empty}
  def select([], plugin_id), do: {:error, {:plugin_not_configured, plugin_id}}

  def select(plugins, nil) when is_list(plugins) do
    case Enum.find(plugins, & &1.enabled) || List.first(plugins) do
      %ConfigSchema.PluginEntry{} = plugin -> {:ok, plugin}
      _plugin -> {:error, :plugin_config_empty}
    end
  end

  def select(plugins, plugin_id) when is_list(plugins) and is_binary(plugin_id) do
    case Enum.find(plugins, &(&1.id == plugin_id)) do
      %ConfigSchema.PluginEntry{} = plugin -> {:ok, plugin}
      nil -> {:error, {:plugin_not_configured, plugin_id}}
    end
  end

  @doc """
  Converts loader-only config fields into keyword options.
  """
  @spec loader_opts(ConfigSchema.PluginEntry.t()) :: keyword()
  def loader_opts(%ConfigSchema.PluginEntry{} = plugin) do
    []
    |> maybe_put_opt(:expected_checksum, plugin.expected_checksum)
    |> maybe_put_opt(:manifest_filename, plugin.manifest_filename)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
