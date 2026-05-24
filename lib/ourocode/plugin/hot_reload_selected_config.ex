defmodule Ourocode.Plugin.HotReloadSelectedConfig do
  @moduledoc """
  Applies hot reload state transitions for one selected configured plugin.
  """

  alias Ourocode.Plugin.HotReloadConfigState
  alias Ourocode.Plugin.HotReloadFailure
  alias Ourocode.Plugin.HotReloadPluginSelection
  alias Ourocode.Plugin.HotReloadRegistryState
  alias Ourocode.Plugin.HotReloadSettings
  alias Ourocode.Plugin.HotReloadTransition

  @type reload_fun :: (map(), Path.t(), keyword() -> {:ok, map()} | {:error, term()})

  @spec apply(map(), list(), keyword(), reload_fun()) :: {:ok, map()} | {:error, term()}
  def apply(
        %{generation: generation, registry: _current_registry} = state,
        plugins,
        opts,
        reload_fun
      )
      when is_integer(generation) and is_list(plugins) and is_list(opts) and
             is_function(reload_fun, 3) do
    plugin_id = Keyword.get(opts, :plugin_id)

    with {:ok, plugin_entry} <- HotReloadPluginSelection.select(plugins, plugin_id) do
      cond do
        settings_only_reload?(opts) ->
          {:ok, HotReloadSettings.apply(state, plugin_entry, opts)}

        plugin_entry.enabled ->
          reload_enabled_plugin(state, plugins, plugin_entry, opts, reload_fun)

        true ->
          {:ok, disable_plugin(state, plugins, plugin_entry, opts)}
      end
    end
  end

  defp reload_enabled_plugin(
         %{generation: generation, registry: current_registry} = state,
         plugins,
         plugin_entry,
         opts,
         reload_fun
       ) do
    {config_state, transitions, state_with_config} = state_with_config(state, plugins)

    reload_opts =
      opts
      |> Keyword.put_new(:reason, :plugin_config_hot_reload)
      |> Keyword.merge(HotReloadPluginSelection.loader_opts(plugin_entry))

    case reload_fun.(state_with_config, plugin_entry.path, reload_opts) do
      {:ok, reloaded} ->
        {:ok,
         reloaded
         |> HotReloadFailure.clear(plugin_entry.id)
         |> put_config_state(config_state, transitions)}

      {:error, reason} ->
        {:ok,
         HotReloadFailure.apply_failure(
           state_with_config,
           plugin_entry,
           reason,
           transitions,
           generation,
           current_registry,
           opts
         )}
    end
  end

  defp disable_plugin(state, plugins, plugin_entry, opts) do
    {config_state, transitions, state_with_config} = state_with_config(state, plugins)

    state_with_config
    |> HotReloadRegistryState.restore_base_registry(
      HotReloadConfigState.plugin_status(plugin_entry),
      opts
    )
    |> put_config_state(config_state, transitions)
  end

  defp state_with_config(state, plugins) do
    config_state = HotReloadConfigState.build(plugins)
    transitions = HotReloadTransition.build(Map.get(state, :plugin_config, %{}), config_state)
    state_with_config = put_config_state(state, config_state, transitions)
    {config_state, transitions, state_with_config}
  end

  defp settings_only_reload?(opts) do
    Keyword.get(opts, :settings_only, false) or
      Keyword.get(opts, :reason) == :plugin_settings_hot_reload
  end

  defp put_config_state(state, config_state, transitions) do
    state
    |> Map.put(:plugin_config, config_state)
    |> Map.put(:plugin_transitions, transitions)
  end
end
