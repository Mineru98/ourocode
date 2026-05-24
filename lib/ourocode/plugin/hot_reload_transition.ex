defmodule Ourocode.Plugin.HotReloadTransition do
  @moduledoc """
  Pure transition projections for plugin hot reload config changes.
  """

  @spec build(map(), map()) :: [map()]
  def build(previous_config_state, next_config_state) do
    previous = Map.get(previous_config_state, :plugins_by_id, %{})
    next = Map.get(next_config_state, :plugins_by_id, %{})

    transitioned =
      next
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&plugin_transition(Map.get(previous, &1.id), &1))

    removed =
      previous
      |> Map.drop(Map.keys(next))
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&removed_plugin_transition/1)

    transitioned ++ removed
  end

  @spec mark_load_failed([map()], String.t(), map()) :: [map()]
  def mark_load_failed(transitions, plugin_id, failure) do
    Enum.map(transitions, fn
      %{plugin_id: ^plugin_id} = transition ->
        transition
        |> Map.put(:action, :load_failed)
        |> Map.put(:to, :load_failed)
        |> Map.put(:loadable?, false)
        |> Map.put(:reason, failure.reason)
        |> Map.put(:load_error, failure)

      transition ->
        transition
    end)
  end

  defp plugin_transition(nil, %{enabled?: true} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :unconfigured,
      to: :enabled,
      action: :load_requested,
      loadable?: true,
      reason: :enabled_in_config
    }
  end

  defp plugin_transition(nil, %{enabled?: false} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :unconfigured,
      to: :disabled,
      action: :skip_load,
      loadable?: false,
      reason: :disabled_in_config
    }
  end

  defp plugin_transition(%{state: :load_failed}, %{enabled?: true} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :load_failed,
      to: :enabled,
      action: :load_requested,
      loadable?: true,
      reason: :enabled_in_config
    }
  end

  defp plugin_transition(%{state: :load_failed}, %{enabled?: false} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :load_failed,
      to: :disabled,
      action: :skip_load,
      loadable?: false,
      reason: :disabled_in_config
    }
  end

  defp plugin_transition(%{enabled?: true}, %{enabled?: false} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :enabled,
      to: :disabled,
      action: :unload_requested,
      loadable?: false,
      reason: :disabled_in_config
    }
  end

  defp plugin_transition(%{enabled?: false}, %{enabled?: true} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :disabled,
      to: :enabled,
      action: :load_requested,
      loadable?: true,
      reason: :enabled_in_config
    }
  end

  defp plugin_transition(%{enabled?: true}, %{enabled?: true} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :enabled,
      to: :enabled,
      action: :keep_loaded,
      loadable?: true,
      reason: :enabled_preserved
    }
  end

  defp plugin_transition(%{enabled?: false}, %{enabled?: false} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :disabled,
      to: :disabled,
      action: :keep_disabled,
      loadable?: false,
      reason: :disabled_preserved
    }
  end

  defp removed_plugin_transition(plugin) do
    %{
      plugin_id: plugin.id,
      from: plugin.state,
      to: :unconfigured,
      action: :unload_requested,
      loadable?: false,
      reason: :removed_from_config
    }
  end
end
