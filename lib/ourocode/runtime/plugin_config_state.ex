defmodule Ourocode.Runtime.PluginConfigState do
  @moduledoc """
  Projects parsed plugin config into runtime registry state.
  """

  alias Ourocode.Plugin.ConfigSchema

  @spec from_config(ConfigSchema.t() | nil | term()) :: map()
  def from_config(%ConfigSchema{plugins: plugins}) do
    configured_plugins = Enum.map(plugins, &configured_plugin_state/1)
    enabled_plugins = configured_plugins |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.id)
    disabled_plugins = configured_plugins |> Enum.reject(& &1.enabled?) |> Enum.map(& &1.id)

    %{
      config_loaded?: true,
      configured_plugins: configured_plugins,
      enabled_plugins: enabled_plugins,
      disabled_plugins: disabled_plugins,
      plugins_by_id: Map.new(configured_plugins, &{&1.id, &1}),
      load_transitions: Enum.map(configured_plugins, &plugin_load_transition/1)
    }
  end

  def from_config(_plugin_config) do
    %{
      config_loaded?: false,
      configured_plugins: [],
      enabled_plugins: [],
      disabled_plugins: [],
      plugins_by_id: %{},
      load_transitions: []
    }
  end

  defp configured_plugin_state(%ConfigSchema.PluginEntry{} = plugin) do
    %{
      id: plugin.id,
      enabled?: plugin.enabled,
      state: if(plugin.enabled, do: :enabled, else: :disabled),
      source: plugin.source,
      path: plugin.path,
      entrypoint: plugin.entrypoint,
      trust_policy: plugin.trust_policy,
      trust_evaluation: plugin.trust_evaluation,
      provenance: plugin.provenance,
      package_identity: ConfigSchema.to_map(plugin)["package_identity"]
    }
  end

  defp plugin_load_transition(%{enabled?: true} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :configured,
      to: :enabled,
      action: :load_requested,
      loadable?: true,
      reason: :enabled_in_config
    }
  end

  defp plugin_load_transition(%{enabled?: false} = plugin) do
    %{
      plugin_id: plugin.id,
      from: :configured,
      to: :disabled,
      action: :skip_load,
      loadable?: false,
      reason: :disabled_in_config
    }
  end
end
