defmodule Ourocode.Plugin.HotReloadConfigState do
  @moduledoc """
  Pure config-state projections for plugin hot reloads.
  """

  alias Ourocode.Plugin.ConfigSchema

  @spec build([ConfigSchema.PluginEntry.t()]) :: map()
  def build(plugins) when is_list(plugins) do
    plugin_states = Enum.map(plugins, &plugin_status/1)
    plugins_by_id = Map.new(plugin_states, &{&1.id, &1})

    %{
      configured_plugins: plugin_states,
      enabled_plugins: enabled_plugin_ids(plugin_states),
      disabled_plugins: disabled_plugin_ids(plugin_states),
      failed_plugins: failed_plugin_ids(plugins_by_id),
      plugins_by_id: plugins_by_id
    }
  end

  @spec plugin_status(ConfigSchema.PluginEntry.t()) :: map()
  def plugin_status(%ConfigSchema.PluginEntry{} = plugin) do
    %{
      id: plugin.id,
      enabled?: plugin.enabled,
      state: if(plugin.enabled, do: :enabled, else: :disabled),
      source: plugin.source,
      path: plugin.path,
      entrypoint: plugin.entrypoint,
      settings: plugin.settings,
      trust_policy: plugin.trust_policy,
      trust_evaluation: plugin.trust_evaluation,
      provenance: plugin.provenance,
      package_identity: ConfigSchema.to_map(plugin)["package_identity"]
    }
  end

  @spec replace_plugin_status(map(), map()) :: map()
  def replace_plugin_status(config_state, target_status) when is_map(config_state) do
    configured_plugins = Map.get(config_state, :configured_plugins, [])
    plugins_by_id = Map.get(config_state, :plugins_by_id, %{})
    had_plugin? = Map.has_key?(plugins_by_id, target_status.id)

    configured_plugins =
      configured_plugins
      |> Enum.map(fn
        %{id: id} when id == target_status.id -> target_status
        plugin -> plugin
      end)
      |> maybe_append_plugin_status(target_status, had_plugin?)

    plugins_by_id = Map.put(plugins_by_id, target_status.id, target_status)

    config_state
    |> Map.put(:configured_plugins, configured_plugins)
    |> Map.put(:enabled_plugins, enabled_plugin_ids(configured_plugins))
    |> Map.put(:disabled_plugins, disabled_plugin_ids(configured_plugins))
    |> Map.put(:failed_plugins, failed_plugin_ids(plugins_by_id))
    |> Map.put(:plugins_by_id, plugins_by_id)
  end

  @spec settings_transition(map() | nil, map()) :: map()
  def settings_transition(nil, target_status) do
    %{
      plugin_id: target_status.id,
      from: :unconfigured,
      to: target_status.state,
      action: :settings_reloaded,
      loadable?: target_status.enabled?,
      reason: :plugin_settings_changed
    }
  end

  def settings_transition(previous_status, target_status) do
    %{
      plugin_id: target_status.id,
      from: previous_status.state,
      to: target_status.state,
      action: :settings_reloaded,
      loadable?: target_status.enabled?,
      reason: :plugin_settings_changed
    }
  end

  @spec put_failed_plugin_status(map(), map()) :: map()
  def put_failed_plugin_status(config_state, failed_status) do
    plugins_by_id = Map.put(config_state.plugins_by_id, failed_status.id, failed_status)

    configured_plugins =
      config_state.configured_plugins
      |> Enum.map(fn
        %{id: id} when id == failed_status.id -> failed_status
        plugin -> plugin
      end)

    config_state
    |> Map.put(:configured_plugins, configured_plugins)
    |> Map.put(:plugins_by_id, plugins_by_id)
    |> Map.put(:failed_plugins, failed_plugin_ids(plugins_by_id))
  end

  @spec failed_plugin_ids(map()) :: [String.t()]
  def failed_plugin_ids(plugins_by_id) when is_map(plugins_by_id) do
    plugins_by_id
    |> Map.values()
    |> Enum.filter(&(&1.state == :load_failed))
    |> Enum.map(& &1.id)
  end

  defp maybe_append_plugin_status(configured_plugins, _target_status, true),
    do: configured_plugins

  defp maybe_append_plugin_status(configured_plugins, target_status, false),
    do: configured_plugins ++ [target_status]

  defp enabled_plugin_ids(plugin_states) do
    plugin_states |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.id)
  end

  defp disabled_plugin_ids(plugin_states) do
    plugin_states |> Enum.reject(& &1.enabled?) |> Enum.map(& &1.id)
  end
end
