defmodule Ourocode.Terminal.PluginStatusTransitions do
  @moduledoc """
  Projects plugin hot-reload transitions onto configured status entries.
  """

  alias Ourocode.Terminal.PluginStatusFields

  @spec apply(map(), [map()]) :: [map()]
  def apply(report, configured_plugins) when is_map(report) and is_list(configured_plugins) do
    transitions = transition_events(report)

    case transitions do
      [_ | _] -> hot_reload_status_entries(report, configured_plugins, transitions)
      _transitions -> configured_plugins
    end
  end

  defp transition_events(report) do
    case value(report, :plugin_transitions, []) do
      [_ | _] = transitions -> transitions
      _empty -> value(report, :load_transitions, [])
    end
  end

  defp hot_reload_status_entries(report, configured_plugins, transitions) do
    plugins_by_id =
      report
      |> value(:plugins_by_id, Map.new(configured_plugins, &{text_value(&1, :id), &1}))
      |> normalize_plugins_by_id()

    transitions_by_id =
      Map.new(transitions, fn transition ->
        {text_value(transition, :plugin_id) || "plugin", transition}
      end)

    configured_plugins
    |> Enum.map(fn plugin ->
      plugin_id = text_value(plugin, :id) || text_value(plugin, :plugin_id) || "plugin"
      plugin = Map.get(plugins_by_id, plugin_id, plugin)

      case Map.fetch(transitions_by_id, plugin_id) do
        {:ok, transition} -> transition_status_entry(plugin_id, plugin, transition)
        :error -> plugin
      end
    end)
    |> Kernel.++(transition_only_status_entries(plugins_by_id, transitions, configured_plugins))
  end

  defp transition_status_entry(plugin_id, plugin, transition) do
    load_error = value(transition, :load_error) || value(plugin, :load_error)

    plugin
    |> Map.merge(%{
      plugin_id: plugin_id,
      id: text_value(plugin, :id) || plugin_id,
      enabled?: transition_enabled?(transition, plugin),
      state: transition_load_state(transition),
      load_state: transition_load_state(transition),
      status_entry: transition_status_entry(transition),
      transition_action: value(transition, :action),
      transition_reason: value(transition, :reason)
    })
    |> maybe_put(:load_error, load_error)
  end

  defp transition_only_status_entries(plugins_by_id, transitions, configured_plugins) do
    configured_ids =
      MapSet.new(
        configured_plugins,
        &(text_value(&1, :id) || text_value(&1, :plugin_id) || "plugin")
      )

    transitions
    |> Enum.reject(fn transition ->
      MapSet.member?(configured_ids, text_value(transition, :plugin_id) || "plugin")
    end)
    |> Enum.map(fn transition ->
      plugin_id = text_value(transition, :plugin_id) || "plugin"
      transition_status_entry(plugin_id, Map.get(plugins_by_id, plugin_id, %{}), transition)
    end)
  end

  defp normalize_plugins_by_id(plugins_by_id) when is_map(plugins_by_id) do
    Map.new(plugins_by_id, fn {plugin_id, plugin} -> {to_string(plugin_id), plugin} end)
  end

  defp normalize_plugins_by_id(_plugins_by_id), do: %{}

  defp transition_enabled?(transition, plugin) do
    case transition_load_state(transition) do
      :disabled -> false
      :load_failed -> boolean_value(plugin, :enabled?, true)
      :newly_loaded -> true
      :enabled -> true
      _state -> boolean_value(plugin, :enabled?, false)
    end
  end

  defp transition_load_state(transition) do
    action = value(transition, :action)
    to = value(transition, :to)

    cond do
      action in [:load_failed, "load_failed"] or to in [:load_failed, "load_failed"] ->
        :load_failed

      action in [:load_requested, "load_requested"] ->
        :newly_loaded

      action in [
        :skip_load,
        "skip_load",
        :unload_requested,
        "unload_requested",
        :keep_disabled,
        "keep_disabled"
      ] or to in [:disabled, "disabled", :unconfigured, "unconfigured"] ->
        :disabled

      to in [:enabled, "enabled"] ->
        :enabled

      true ->
        :unknown
    end
  end

  defp transition_status_entry(transition) do
    case transition_load_state(transition) do
      :newly_loaded -> :newly_loaded_plugin
      :disabled -> :disabled_plugin
      :load_failed -> :failed_plugin
      state -> state
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key, default \\ nil), do: PluginStatusFields.value(map, key, default)
  defp text_value(map, key), do: PluginStatusFields.text(map, key)
  defp boolean_value(map, key, default), do: PluginStatusFields.boolean(map, key, default)
end
