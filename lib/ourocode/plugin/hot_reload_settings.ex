defmodule Ourocode.Plugin.HotReloadSettings do
  @moduledoc """
  Applies settings-only plugin hot reloads without rebuilding plugin registries.
  """

  alias Ourocode.Plugin.HotReloadConfigState

  @spec apply(map(), map(), keyword()) :: map()
  def apply(%{generation: generation, registry: current_registry} = state, plugin_entry, opts)
      when is_integer(generation) and is_map(plugin_entry) and is_list(opts) do
    previous_config_state =
      Map.get_lazy(state, :plugin_config, fn ->
        HotReloadConfigState.build([plugin_entry])
      end)

    previous_status = get_in(previous_config_state, [:plugins_by_id, plugin_entry.id])

    target_status =
      (previous_status || HotReloadConfigState.plugin_status(plugin_entry))
      |> Map.put(:settings, plugin_entry.settings)

    next_config_state =
      HotReloadConfigState.replace_plugin_status(previous_config_state, target_status)

    transitions = [HotReloadConfigState.settings_transition(previous_status, target_status)]

    state
    |> Map.put(:plugin_config, next_config_state)
    |> Map.put(:plugin_transitions, transitions)
    |> Map.put(:generation, generation + 1)
    |> Map.put(:previous_registry, current_registry)
    |> Map.put(:registry, current_registry)
    |> Map.put(:plugin, target_status)
    |> Map.put(
      :loaded_at_ms,
      Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
    )
    |> Map.put(:reason, Keyword.get(opts, :reason, :plugin_settings_hot_reload))
  end
end
