defmodule Ourocode.Plugin.HotReloadFailure do
  @moduledoc """
  Load-failure state transitions for plugin hot reloads.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.HotReloadConfigState
  alias Ourocode.Plugin.HotReloadTransition
  alias Ourocode.Plugin.LoadError

  @spec apply_failure(
          map(),
          ConfigSchema.PluginEntry.t(),
          term(),
          [map()],
          non_neg_integer(),
          map(),
          keyword()
        ) :: map()
  def apply_failure(
        state,
        %ConfigSchema.PluginEntry{} = plugin_entry,
        reason,
        transitions,
        generation,
        current_registry,
        opts
      )
      when is_map(state) and is_list(transitions) and is_integer(generation) and
             is_map(current_registry) and is_list(opts) do
    failure = failure(plugin_entry, reason, opts)

    failed_status =
      plugin_entry
      |> HotReloadConfigState.plugin_status()
      |> Map.merge(%{state: :load_failed, load_error: failure})

    config_state =
      HotReloadConfigState.put_failed_plugin_status(state.plugin_config, failed_status)

    failed_transitions =
      HotReloadTransition.mark_load_failed(transitions, plugin_entry.id, failure)

    state
    |> put_config_state(config_state, failed_transitions)
    |> Map.put(:generation, generation + 1)
    |> Map.put(:previous_registry, current_registry)
    |> Map.put(:registry, current_registry)
    |> Map.put(:plugin, failed_status)
    |> Map.put(:plugin_load_failures, [failure | Map.get(state, :plugin_load_failures, [])])
    |> Map.put(
      :loaded_at_ms,
      Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
    )
    |> Map.put(:reason, :plugin_config_load_failed)
  end

  @spec clear(map(), String.t()) :: map()
  def clear(state, plugin_id) do
    case Map.fetch(state, :plugin_load_failures) do
      {:ok, failures} when is_list(failures) ->
        active_failures = Enum.reject(failures, &(&1.plugin_id == plugin_id))
        Map.put(state, :plugin_load_failures, active_failures)

      _missing_or_invalid ->
        state
    end
  end

  @spec failure(ConfigSchema.PluginEntry.t(), term(), keyword()) :: map()
  def failure(%ConfigSchema.PluginEntry{} = plugin_entry, %LoadError{} = error, opts) do
    %{
      plugin_id: plugin_entry.id,
      state: :load_failed,
      reason: error.reason,
      message: error.message,
      plugin_path: error.plugin_path,
      manifest_path: error.manifest_path,
      source: plugin_entry.source,
      trust_policy: plugin_entry.trust_policy,
      attempted_at_ms: Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
    }
  end

  def failure(%ConfigSchema.PluginEntry{} = plugin_entry, reason, opts) do
    %{
      plugin_id: plugin_entry.id,
      state: :load_failed,
      reason: reason,
      message: "plugin #{inspect(plugin_entry.path)} failed to load with #{inspect(reason)}",
      plugin_path: plugin_entry.path,
      manifest_path: nil,
      source: plugin_entry.source,
      trust_policy: plugin_entry.trust_policy,
      attempted_at_ms: Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
    }
  end

  defp put_config_state(state, config_state, transitions) do
    state
    |> Map.put(:plugin_config, config_state)
    |> Map.put(:plugin_transitions, transitions)
  end
end
