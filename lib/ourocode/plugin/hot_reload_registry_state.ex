defmodule Ourocode.Plugin.HotReloadRegistryState do
  @moduledoc """
  Registry state transitions shared by plugin hot reload paths.
  """

  @spec normalize_registry(map()) :: map()
  def normalize_registry(registry) when is_map(registry) do
    %{
      adapters: Map.get(registry, :adapters, %{}),
      renderers: Map.get(registry, :renderers, %{}),
      actions: Map.get(registry, :actions, %{})
    }
  end

  @spec registry_sources(map(), atom()) :: map()
  def registry_sources(registry, source) when is_map(registry) do
    registry = normalize_registry(registry)

    %{
      adapters: Map.new(registry.adapters, fn {key, _value} -> {key, source} end),
      renderers: Map.new(registry.renderers, fn {key, _value} -> {key, source} end),
      actions: Map.new(registry.actions, fn {key, _value} -> {key, source} end)
    }
  end

  @spec restore_base_registry(map(), map() | nil, keyword()) :: map()
  def restore_base_registry(
        %{generation: generation, registry: current_registry} = state,
        plugin_status,
        opts
      )
      when is_integer(generation) and is_map(current_registry) and is_list(opts) do
    base_registry = Map.get(state, :base_registry, current_registry)

    state
    |> Map.put(:generation, generation + 1)
    |> Map.put(:previous_registry, current_registry)
    |> Map.put(:registry, base_registry)
    |> Map.put(:base_registry, base_registry)
    |> Map.put(:plugin, plugin_status)
    |> Map.put(
      :sources,
      Map.get_lazy(state, :base_sources, fn -> registry_sources(base_registry, :local) end)
    )
    |> Map.put(
      :loaded_at_ms,
      Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
    )
    |> Map.put(:reason, Keyword.get(opts, :reason, :plugin_config_hot_reload))
  end
end
