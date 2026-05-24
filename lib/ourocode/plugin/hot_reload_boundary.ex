defmodule Ourocode.Plugin.HotReloadBoundary do
  @moduledoc """
  Adaptive hot reload boundary for plugin strategies.

  The Elixir runtime keeps session state, journal cursors, pane state, and
  supervision as the source of truth. This boundary only reloads verified plugin
  strategy code and resolves a fresh adapter/renderer/action registry, so a
  plugin update can take effect without replacing the running runtime state.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.HotReloadConfigState
  alias Ourocode.Plugin.HotReloadCompiler
  alias Ourocode.Plugin.HotReloadFailure
  alias Ourocode.Plugin.HotReloadPluginSelection
  alias Ourocode.Plugin.HotReloadRegistryState
  alias Ourocode.Plugin.HotReloadSelectedConfig
  alias Ourocode.Plugin.HotReloadTransition
  alias Ourocode.Plugin.MappingResolver

  @type reload_state :: %{
          required(:generation) => non_neg_integer(),
          required(:registry) => map(),
          optional(:base_registry) => map(),
          optional(:base_sources) => map(),
          optional(:plugin) => map(),
          optional(:plugin_config) => map(),
          optional(:plugin_transitions) => [map()],
          optional(:plugin_load_failures) => [map()],
          optional(:sources) => map(),
          optional(:previous_registry) => map(),
          optional(:loaded_at_ms) => integer(),
          optional(:reason) => term()
        }

  @doc """
  Returns an empty hot reload state.
  """
  @spec new(map()) :: reload_state()
  def new(registry \\ %{}) when is_map(registry) do
    normalized_registry = HotReloadRegistryState.normalize_registry(registry)

    %{
      generation: 0,
      registry: normalized_registry,
      base_registry: normalized_registry,
      base_sources: HotReloadRegistryState.registry_sources(normalized_registry, :local)
    }
  end

  @doc """
  Compiles changed plugin source files under allowed roots, then resolves and
  installs the verified active registry for the next generation.

  `:compile_paths` is optional. Each source path is validated by
  `Ourocode.Plugin.PathPolicy` before `Code.compile_file/1` runs.
  """
  @spec reload(reload_state(), Path.t(), keyword()) :: {:ok, reload_state()} | {:error, term()}
  def reload(
        %{generation: generation, registry: current_registry} = state,
        plugin_path,
        opts \\ []
      )
      when is_integer(generation) and is_binary(plugin_path) and is_list(opts) do
    base_registry = Map.get(state, :base_registry, current_registry)

    base_sources =
      Map.get_lazy(state, :base_sources, fn ->
        HotReloadRegistryState.registry_sources(base_registry, :local)
      end)

    with :ok <- HotReloadCompiler.compile_changed_sources(opts),
         {:ok, resolved} <-
           MappingResolver.resolve_active_registry(
             plugin_path,
             Keyword.get(opts, :user_registry, %{}),
             Keyword.get(opts, :local_registry, base_registry),
             opts
           ) do
      {:ok,
       state
       |> Map.put(:generation, generation + 1)
       |> Map.put(:previous_registry, current_registry)
       |> Map.put(:base_registry, base_registry)
       |> Map.put(:base_sources, base_sources)
       |> Map.put(:registry, resolved.registry)
       |> Map.put(:plugin, resolved.plugin)
       |> Map.put(:sources, resolved.sources)
       |> Map.put(
         :loaded_at_ms,
         Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
       )
       |> Map.put(:reason, Keyword.get(opts, :reason, :plugin_changed))}
    end
  end

  @doc """
  Applies a parsed plugin config hot-reload to the active boundary state.

  Enabled plugins are loaded through the normal hot-reload path. Disabled
  plugins are recorded as disabled and their previously loaded registry entries
  are removed by restoring the runtime-owned base registry. The enabled boolean
  from config is preserved in `:plugin_config` for UI/status panes and replay.
  """
  @spec reload_config(
          reload_state(),
          ConfigSchema.t() | [ConfigSchema.PluginEntry.t()],
          keyword()
        ) ::
          {:ok, reload_state()} | {:error, term()}
  def reload_config(state, %ConfigSchema{plugins: plugins}, opts) when is_list(opts) do
    reload_config(state, plugins, opts)
  end

  def reload_config(%{generation: generation} = state, plugins, opts)
      when is_integer(generation) and is_list(plugins) and is_list(opts) do
    if Keyword.has_key?(opts, :plugin_id) or length(plugins) <= 1 do
      reload_selected_config(state, plugins, opts)
    else
      reload_all_config(state, plugins, opts)
    end
  end

  defp reload_selected_config(
         state,
         plugins,
         opts
       ) do
    HotReloadSelectedConfig.apply(state, plugins, opts, &reload/3)
  end

  defp reload_all_config(state, plugins, opts) do
    config_state = plugin_config_state(plugins)
    transitions = plugin_transitions(Map.get(state, :plugin_config, %{}), config_state)

    state_with_config = put_config_state(state, config_state, transitions)
    enabled_plugins = Enum.filter(plugins, & &1.enabled)

    case enabled_plugins do
      [] ->
        {:ok,
         state_with_config
         |> HotReloadRegistryState.restore_base_registry(nil, opts)}

      plugins_to_load ->
        {:ok,
         Enum.reduce(plugins_to_load, state_with_config, &reload_configured_plugin(&2, &1, opts))}
    end
  end

  defp reload_configured_plugin(
         %{generation: generation, registry: current_registry} = state,
         plugin_entry,
         opts
       ) do
    reload_opts =
      opts
      |> Keyword.put_new(:reason, :plugin_config_hot_reload)
      |> Keyword.put(:local_registry, current_registry)
      |> Keyword.merge(HotReloadPluginSelection.loader_opts(plugin_entry))

    case reload(state, plugin_entry.path, reload_opts) do
      {:ok, reloaded} ->
        reloaded
        |> HotReloadFailure.clear(plugin_entry.id)
        |> put_config_state(
          Map.fetch!(state, :plugin_config),
          Map.fetch!(state, :plugin_transitions)
        )

      {:error, reason} ->
        HotReloadFailure.apply_failure(
          state,
          plugin_entry,
          reason,
          Map.fetch!(state, :plugin_transitions),
          generation,
          current_registry,
          opts
        )
    end
  end

  defp put_config_state(state, config_state, transitions) do
    state
    |> Map.put(:plugin_config, config_state)
    |> Map.put(:plugin_transitions, transitions)
  end

  defp plugin_config_state(plugins) do
    HotReloadConfigState.build(plugins)
  end

  defp plugin_transitions(previous_config_state, next_config_state) do
    HotReloadTransition.build(previous_config_state, next_config_state)
  end
end
