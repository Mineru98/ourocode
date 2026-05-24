defmodule Ourocode.Runtime.PluginConfigReloadState do
  @moduledoc """
  Pure plugin config reload state and journal event construction.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Runtime.PluginConfigState

  @spec config_state(ConfigSchema.t() | nil | term()) :: map()
  def config_state(plugin_config), do: PluginConfigState.from_config(plugin_config)

  @spec reload_state(tuple(), map(), map(), map()) ::
          {:loaded | :missing | :invalid, term(), map()}
  def reload_state({:ok, source_path, plugin_config}, before_plugins, reload_request, options) do
    reloaded_plugins =
      before_plugins
      |> Map.merge(config_state(plugin_config))
      |> Map.merge(%{
        status: :ready,
        config_loaded?: true,
        config_missing?: false,
        config_invalid?: false,
        config_error: nil,
        config_source_path: Path.expand(source_path),
        last_reload: reload_metadata(:loaded, reload_request, options)
      })

    {:loaded, plugin_config, reloaded_plugins}
  end

  def reload_state({:missing, source_path, reason}, before_plugins, reload_request, options) do
    missing_plugins =
      before_plugins
      |> Map.merge(config_state(nil))
      |> Map.merge(%{
        status: :missing,
        config_loaded?: false,
        config_missing?: true,
        config_invalid?: false,
        config_error: reason,
        config_source_path: source_path && Path.expand(source_path),
        last_reload: reload_metadata(:missing, reload_request, options)
      })

    {:missing, nil, missing_plugins}
  end

  def reload_state({:invalid, source_path, reason}, before_plugins, reload_request, options) do
    invalid_plugins =
      before_plugins
      |> Map.merge(config_state(nil))
      |> Map.merge(%{
        status: :invalid,
        config_loaded?: false,
        config_missing?: false,
        config_invalid?: true,
        config_error: reason,
        config_source_path: source_path && Path.expand(source_path),
        last_reload: reload_metadata(:invalid, reload_request, options)
      })

    {:invalid, nil, invalid_plugins}
  end

  @spec reloaded_event(map(), map(), map()) :: map()
  def reloaded_event(reload_request, plugins, options) do
    last_reload = Map.fetch!(plugins, :last_reload)

    %{
      type: :plugin_config_reloaded,
      event_type: :plugin_config_reloaded,
      source: :plugin_registry,
      status: last_reload.status,
      request_id: last_reload.request_id,
      change: last_reload.change,
      config_source_path: Map.get(plugins, :config_source_path),
      enabled_plugins: Map.get(plugins, :enabled_plugins, []),
      disabled_plugins: Map.get(plugins, :disabled_plugins, []),
      configured_plugins: Map.get(plugins, :configured_plugins, []),
      configured_plugin_count: length(Map.get(plugins, :configured_plugins, [])),
      plugins_by_id: Map.get(plugins, :plugins_by_id, %{}),
      load_transitions: Map.get(plugins, :load_transitions, []),
      plugin_transitions:
        Map.get(plugins, :plugin_transitions, Map.get(plugins, :load_transitions, [])),
      config_error: Map.get(plugins, :config_error),
      original_reload_request: reload_request,
      occurred_at_ms: Map.get(options, :occurred_at_ms, last_reload.occurred_at_ms),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false
    }
  end

  defp reload_metadata(status, reload_request, options) do
    %{
      status: status,
      request_id: value(reload_request, :request_id),
      change: value(reload_request, :change),
      source: value(reload_request, :source, :plugin_config_reload_handler),
      occurred_at_ms: Map.get(options, :occurred_at_ms, System.system_time(:millisecond)),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false
    }
  end

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default
end
