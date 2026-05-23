defmodule Ourocode.Plugin.HotReloadBoundary do
  @moduledoc """
  Adaptive hot reload boundary for plugin strategies.

  The Elixir runtime keeps session state, journal cursors, pane state, and
  supervision as the source of truth. This boundary only reloads verified plugin
  strategy code and resolves a fresh adapter/renderer/action registry, so a
  plugin update can take effect without replacing the running runtime state.
  """

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.LoadError
  alias Ourocode.Plugin.MappingResolver
  alias Ourocode.Plugin.PathPolicy

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
    normalized_registry = normalize_registry(registry)

    %{
      generation: 0,
      registry: normalized_registry,
      base_registry: normalized_registry,
      base_sources: registry_sources(normalized_registry, :local)
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
      Map.get_lazy(state, :base_sources, fn -> registry_sources(base_registry, :local) end)

    with :ok <- compile_changed_sources(opts),
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
         %{generation: generation, registry: current_registry} = state,
         plugins,
         opts
       ) do
    plugin_id = Keyword.get(opts, :plugin_id)

    with {:ok, plugin_entry} <- select_plugin(plugins, plugin_id) do
      if settings_only_reload?(opts) do
        reload_selected_plugin_settings(state, plugin_entry, opts)
      else
        config_state = plugin_config_state(plugins)
        transitions = plugin_transitions(Map.get(state, :plugin_config, %{}), config_state)
        state_with_config = put_config_state(state, config_state, transitions)

        if plugin_entry.enabled do
          reload_opts =
            opts
            |> Keyword.put_new(:reason, :plugin_config_hot_reload)
            |> Keyword.merge(loader_opts(plugin_entry))

          case reload(state_with_config, plugin_entry.path, reload_opts) do
            {:ok, reloaded} ->
              {:ok,
               reloaded
               |> clear_load_failure_state(plugin_entry.id)
               |> put_config_state(config_state, transitions)}

            {:error, reason} ->
              {:ok,
               load_failure_state(
                 state_with_config,
                 plugin_entry,
                 reason,
                 transitions,
                 generation,
                 current_registry,
                 opts
               )}
          end
        else
          base_registry = Map.get(state, :base_registry, current_registry)

          {:ok,
           state_with_config
           |> Map.put(:generation, generation + 1)
           |> Map.put(:previous_registry, current_registry)
           |> Map.put(:registry, base_registry)
           |> Map.put(:base_registry, base_registry)
           |> Map.put(:plugin, plugin_status(plugin_entry))
           |> Map.put(
             :sources,
             Map.get_lazy(state, :base_sources, fn -> registry_sources(base_registry, :local) end)
           )
           |> Map.put(
             :loaded_at_ms,
             Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
           )
           |> Map.put(:reason, Keyword.get(opts, :reason, :plugin_config_hot_reload))}
        end
      end
    end
  end

  defp reload_selected_plugin_settings(
         %{generation: generation, registry: current_registry} = state,
         plugin_entry,
         opts
       ) do
    previous_config_state =
      Map.get_lazy(state, :plugin_config, fn -> plugin_config_state([plugin_entry]) end)

    previous_status = get_in(previous_config_state, [:plugins_by_id, plugin_entry.id])

    target_status =
      (previous_status || plugin_status(plugin_entry))
      |> Map.put(:settings, plugin_entry.settings)

    next_config_state = replace_plugin_status(previous_config_state, target_status)
    transitions = [plugin_settings_transition(previous_status, target_status)]

    {:ok,
     state
     |> put_config_state(next_config_state, transitions)
     |> Map.put(:generation, generation + 1)
     |> Map.put(:previous_registry, current_registry)
     |> Map.put(:registry, current_registry)
     |> Map.put(:plugin, target_status)
     |> Map.put(
       :loaded_at_ms,
       Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
     )
     |> Map.put(:reason, Keyword.get(opts, :reason, :plugin_settings_hot_reload))}
  end

  defp settings_only_reload?(opts) do
    Keyword.get(opts, :settings_only, false) or
      Keyword.get(opts, :reason) == :plugin_settings_hot_reload
  end

  defp replace_plugin_status(config_state, target_status) do
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

  defp plugin_settings_transition(nil, target_status) do
    %{
      plugin_id: target_status.id,
      from: :unconfigured,
      to: target_status.state,
      action: :settings_reloaded,
      loadable?: target_status.enabled?,
      reason: :plugin_settings_changed
    }
  end

  defp plugin_settings_transition(previous_status, target_status) do
    %{
      plugin_id: target_status.id,
      from: previous_status.state,
      to: target_status.state,
      action: :settings_reloaded,
      loadable?: target_status.enabled?,
      reason: :plugin_settings_changed
    }
  end

  defp reload_all_config(
         %{generation: generation, registry: current_registry} = state,
         plugins,
         opts
       ) do
    config_state = plugin_config_state(plugins)
    transitions = plugin_transitions(Map.get(state, :plugin_config, %{}), config_state)

    state_with_config = put_config_state(state, config_state, transitions)
    enabled_plugins = Enum.filter(plugins, & &1.enabled)

    case enabled_plugins do
      [] ->
        base_registry = Map.get(state, :base_registry, current_registry)

        {:ok,
         state_with_config
         |> Map.put(:generation, generation + 1)
         |> Map.put(:previous_registry, current_registry)
         |> Map.put(:registry, base_registry)
         |> Map.put(:base_registry, base_registry)
         |> Map.put(:plugin, nil)
         |> Map.put(
           :sources,
           Map.get_lazy(state, :base_sources, fn -> registry_sources(base_registry, :local) end)
         )
         |> Map.put(
           :loaded_at_ms,
           Keyword.get(opts, :loaded_at_ms, System.system_time(:millisecond))
         )
         |> Map.put(:reason, Keyword.get(opts, :reason, :plugin_config_hot_reload))}

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
      |> Keyword.merge(loader_opts(plugin_entry))

    case reload(state, plugin_entry.path, reload_opts) do
      {:ok, reloaded} ->
        reloaded
        |> clear_load_failure_state(plugin_entry.id)
        |> put_config_state(
          Map.fetch!(state, :plugin_config),
          Map.fetch!(state, :plugin_transitions)
        )

      {:error, reason} ->
        load_failure_state(
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

  defp select_plugin([], nil), do: {:error, :plugin_config_empty}
  defp select_plugin([], plugin_id), do: {:error, {:plugin_not_configured, plugin_id}}

  defp select_plugin(plugins, nil) do
    case Enum.find(plugins, & &1.enabled) || List.first(plugins) do
      %ConfigSchema.PluginEntry{} = plugin -> {:ok, plugin}
      _plugin -> {:error, :plugin_config_empty}
    end
  end

  defp select_plugin(plugins, plugin_id) when is_binary(plugin_id) do
    case Enum.find(plugins, &(&1.id == plugin_id)) do
      %ConfigSchema.PluginEntry{} = plugin -> {:ok, plugin}
      nil -> {:error, {:plugin_not_configured, plugin_id}}
    end
  end

  defp loader_opts(%ConfigSchema.PluginEntry{} = plugin) do
    []
    |> maybe_put_opt(:expected_checksum, plugin.expected_checksum)
    |> maybe_put_opt(:manifest_filename, plugin.manifest_filename)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_config_state(state, config_state, transitions) do
    state
    |> Map.put(:plugin_config, config_state)
    |> Map.put(:plugin_transitions, transitions)
  end

  defp plugin_config_state(plugins) do
    plugin_states = Enum.map(plugins, &plugin_status/1)

    %{
      configured_plugins: plugin_states,
      enabled_plugins: plugin_states |> Enum.filter(& &1.enabled?) |> Enum.map(& &1.id),
      disabled_plugins: plugin_states |> Enum.reject(& &1.enabled?) |> Enum.map(& &1.id),
      failed_plugins:
        plugin_states
        |> Enum.filter(&(&1.state == :load_failed))
        |> Enum.map(& &1.id),
      plugins_by_id: Map.new(plugin_states, &{&1.id, &1})
    }
  end

  defp plugin_status(%ConfigSchema.PluginEntry{} = plugin) do
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

  defp load_failure_state(
         state,
         %ConfigSchema.PluginEntry{} = plugin_entry,
         reason,
         transitions,
         generation,
         current_registry,
         opts
       ) do
    failure = load_failure(plugin_entry, reason, opts)

    failed_status =
      plugin_entry |> plugin_status() |> Map.merge(%{state: :load_failed, load_error: failure})

    config_state = put_failed_plugin_status(state.plugin_config, failed_status)

    failed_transitions = mark_load_failed_transitions(transitions, plugin_entry.id, failure)

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

  defp load_failure(%ConfigSchema.PluginEntry{} = plugin_entry, %LoadError{} = error, opts) do
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

  defp load_failure(%ConfigSchema.PluginEntry{} = plugin_entry, reason, opts) do
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

  defp put_failed_plugin_status(config_state, failed_status) do
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

  defp clear_load_failure_state(state, plugin_id) do
    case Map.fetch(state, :plugin_load_failures) do
      {:ok, failures} when is_list(failures) ->
        active_failures = Enum.reject(failures, &(&1.plugin_id == plugin_id))
        Map.put(state, :plugin_load_failures, active_failures)

      _missing_or_invalid ->
        state
    end
  end

  defp failed_plugin_ids(plugins_by_id) do
    plugins_by_id
    |> Map.values()
    |> Enum.filter(&(&1.state == :load_failed))
    |> Enum.map(& &1.id)
  end

  defp mark_load_failed_transitions(transitions, plugin_id, failure) do
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

  defp plugin_transitions(previous_config_state, next_config_state) do
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

  defp compile_changed_sources(opts) do
    opts
    |> Keyword.get(:compile_paths, [])
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case compile_source(path, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_source(path, opts) when is_binary(path) do
    with {:ok, source_path} <- PathPolicy.validate(path, opts) do
      Code.compile_file(source_path)
      :ok
    end
  rescue
    exception -> {:error, {:compile_failed, path, Exception.message(exception)}}
  end

  defp compile_source(path, _opts), do: {:error, {:invalid_compile_path, path}}

  defp normalize_registry(registry) do
    %{
      adapters: Map.get(registry, :adapters, %{}),
      renderers: Map.get(registry, :renderers, %{}),
      actions: Map.get(registry, :actions, %{})
    }
  end

  defp registry_sources(registry, source) do
    %{
      adapters: Map.new(registry.adapters, fn {key, _value} -> {key, source} end),
      renderers: Map.new(registry.renderers, fn {key, _value} -> {key, source} end),
      actions: Map.new(registry.actions, fn {key, _value} -> {key, source} end)
    }
  end
end
