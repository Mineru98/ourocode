defmodule Ourocode.Runtime.Application do
  @moduledoc """
  Runtime bootstrap boundary for one interactive terminal session.

  Elixir owns the runtime state for the terminal app, so bootstrap starts the
  small OTP service set that later panes, transports, plugins, hooks, command
  discovery, wonderTool, and replay work can attach to.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Config
  alias Ourocode.Journal
  alias Ourocode.Journal.SourceTransportNormalizer
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Plugin.ConfigWatcher
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Runtime.Stream.Session

  @service_ids [
    :runtime_registry,
    :transport_supervisor,
    :session_supervisor,
    :child_supervisor,
    :event_pipeline,
    :pane_model,
    :focus_state,
    :plugin_registry,
    :plugin_config_watcher,
    :command_registry,
    :queued_notifications,
    :hook_lifecycle,
    :wonder_tool
  ]

  @type bootstrap_result :: %{
          required(:status) => :ready,
          required(:healthy?) => true,
          required(:session_id) => String.t(),
          required(:supervisor_pid) => pid(),
          required(:services) => %{required(atom()) => pid()},
          required(:service_statuses) => %{required(atom()) => :ready},
          required(:journal) => map(),
          required(:event_pipeline) => map(),
          required(:pane_model) => map(),
          required(:focus_state) => map(),
          required(:plugins) => map(),
          required(:plugin_config_watcher) => map(),
          required(:commands) => map(),
          required(:queued_notifications) => map(),
          required(:hooks) => map(),
          required(:wonder_tool) => map()
        }

  @doc """
  Starts the runtime services and returns the initialized terminal session state.
  """
  @spec bootstrap(map()) :: {:ok, bootstrap_result()} | {:error, map()}
  def bootstrap(%{project_dir: project_dir, config: config} = context)
      when is_binary(project_dir) and is_map(config) do
    project_dir = Path.expand(project_dir)
    session_id = session_id(context)
    context = Map.put(context, :runtime_session_id, session_id)

    with :ok <- ensure_project_dir(project_dir),
         {:ok, journal_path} <- prepare_journal_path(context, project_dir),
         {:ok, supervisor_pid, services, registry_name} <-
           start_runtime_services(context, project_dir, journal_path) do
      {:ok,
       %{
         status: :ready,
         healthy?: true,
         session_id: session_id,
         supervisor_pid: supervisor_pid,
         services: services,
         service_statuses: service_statuses(services),
         registry_name: registry_name,
         journal: journal_state(journal_path),
         event_pipeline: event_pipeline_state(config),
         pane_model: pane_model_state(),
         focus_state: focus_state(),
         plugins: plugin_state(context),
         plugin_config_watcher: plugin_config_watcher_state(services, project_dir),
         commands: command_registry_state(context),
         queued_notifications: queued_notification_state(),
         hooks: hook_lifecycle_state(),
         wonder_tool: wonder_tool_state(project_dir, journal_path)
       }}
    end
  end

  def bootstrap(_context) do
    {:error,
     %{
       status: :unhealthy,
       healthy?: false,
       reason: :invalid_runtime_bootstrap_context
     }}
  end

  @doc """
  Stops a runtime supervisor returned by `bootstrap/1`.
  """
  @spec stop(map()) :: :ok
  def stop(%{supervisor_pid: supervisor_pid}) when is_pid(supervisor_pid) do
    if Process.alive?(supervisor_pid), do: Supervisor.stop(supervisor_pid)
    :ok
  end

  def stop(_runtime), do: :ok

  @doc """
  Requests focus for a pane id known to the runtime pane model.
  """
  @spec focus_pane(map(), FocusState.pane_id(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def focus_pane(runtime, pane_id, options \\ [])

  def focus_pane(%{services: %{pane_model: pane_pid, focus_state: focus_pid}}, pane_id, options)
      when is_pid(pane_pid) and is_pid(focus_pid) do
    pane_model = Agent.get(pane_pid, & &1)

    Agent.get_and_update(focus_pid, fn focus_state ->
      case FocusState.focus_pane(focus_state, pane_id, pane_model, options) do
        {:ok, updated_focus_state, event} ->
          {{:ok, %{focus_state: updated_focus_state, event: event}}, updated_focus_state}

        {:error, reason, unchanged_focus_state} ->
          {{:error, reason}, unchanged_focus_state}
      end
    end)
  end

  def focus_pane(_runtime, pane_id, _options), do: {:error, {:unknown_pane, pane_id}}

  @doc """
  Reads the current runtime focus state.
  """
  @spec current_focus_state(map()) :: {:ok, map()} | {:error, :focus_state_unavailable}
  def current_focus_state(%{services: %{focus_state: focus_pid}}) when is_pid(focus_pid) do
    {:ok, Agent.get(focus_pid, & &1)}
  end

  def current_focus_state(_runtime), do: {:error, :focus_state_unavailable}

  @doc """
  Resolves the concrete child session currently targeted by runtime focus.
  """
  @spec current_focused_child_session(map()) ::
          {:ok, FocusState.focused_child_session()}
          | {:error,
             :no_focused_child_session
             | :focused_child_session_pane_not_found
             | :focus_state_unavailable}
  def current_focused_child_session(%{services: %{pane_model: pane_pid, focus_state: focus_pid}})
      when is_pid(pane_pid) and is_pid(focus_pid) do
    pane_model = Agent.get(pane_pid, & &1)
    focus_state = Agent.get(focus_pid, & &1)

    FocusState.focused_child_session(focus_state, pane_model)
  end

  def current_focused_child_session(_runtime), do: {:error, :focus_state_unavailable}

  @doc """
  Reads the current supervised command registry.
  """
  @spec current_command_registry(map()) :: {:ok, map()} | {:error, :command_registry_unavailable}
  def current_command_registry(%{services: %{command_registry: command_registry_pid}})
      when is_pid(command_registry_pid) do
    {:ok, Agent.get(command_registry_pid, & &1)}
  end

  def current_command_registry(_runtime), do: {:error, :command_registry_unavailable}

  @doc """
  Reads the current supervised plugin registry/status record.
  """
  @spec current_plugin_registry(map()) :: {:ok, map()} | {:error, :plugin_registry_unavailable}
  def current_plugin_registry(%{services: %{plugin_registry: plugin_registry_pid}})
      when is_pid(plugin_registry_pid) do
    {:ok, Agent.get(plugin_registry_pid, & &1)}
  end

  def current_plugin_registry(_runtime), do: {:error, :plugin_registry_unavailable}

  @doc """
  Handles a plugin config watcher reload request at the Elixir runtime boundary.

  The handler re-reads the changed config source and swaps the supervised plugin
  status record in-place. Valid configs refresh the command registry from the
  same parsed plugin config. Invalid configs are reported in plugin status while
  preserving the previous command surface, and missing/deleted configs unload
  plugin commands by replacing the plugin config with an empty state.
  """
  @spec handle_plugin_config_reload(map(), map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def handle_plugin_config_reload(runtime, reload_request, options \\ [])

  def handle_plugin_config_reload(
        %{
          services: %{
            plugin_registry: plugin_registry_pid,
            command_registry: command_registry_pid
          },
          journal: %{path: journal_path}
        },
        reload_request,
        options
      )
      when is_pid(plugin_registry_pid) and is_pid(command_registry_pid) and is_map(reload_request) do
    options = Map.new(options)
    before_plugins = Agent.get(plugin_registry_pid, & &1)
    before_commands = Agent.get(command_registry_pid, & &1)

    {reload_status, plugin_config, next_plugins} =
      reload_request
      |> read_reloaded_plugin_config(options)
      |> plugin_reload_state(before_plugins, reload_request, options)

    next_commands = reloaded_command_registry(reload_status, plugin_config, before_commands)
    reload_event = plugin_config_reloaded_event(reload_request, next_plugins, options)

    with :ok <- Journal.append(journal_path, reload_event) do
      Agent.update(plugin_registry_pid, fn _plugins -> next_plugins end)
      Agent.update(command_registry_pid, fn _commands -> next_commands end)

      {:ok,
       %{
         status: reload_status,
         plugins: next_plugins,
         commands: next_commands,
         event: reload_event,
         journal_path: journal_path
       }}
    end
  end

  def handle_plugin_config_reload(_runtime, _reload_request, _options) do
    {:error, :plugin_registry_unavailable}
  end

  @doc """
  Applies a plugin-scoped settings reload to an already active session and pane.

  The runtime keeps the session process and pane identity intact: settings are
  validated and applied through the live session GenServer, while the pane model
  is updated under the existing pane key. The reload is journaled as a runtime
  event so replay can reconstruct which plugin settings were active.
  """
  @spec apply_plugin_settings_reload(map(), map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def apply_plugin_settings_reload(runtime, reload_request, options \\ [])

  def apply_plugin_settings_reload(
        %{
          services: %{pane_model: pane_model_pid},
          journal: %{path: journal_path}
        },
        reload_request,
        options
      )
      when is_pid(pane_model_pid) and is_binary(journal_path) and is_map(reload_request) do
    options = Map.new(options)

    with {:ok, plugin_id} <- plugin_settings_plugin_id(reload_request, options),
         {:ok, session_pid} <- plugin_settings_session_pid(options),
         {:ok, pane_id, before_pane} <- plugin_settings_pane(pane_model_pid, options),
         {:ok, plugin_settings} <- read_plugin_settings(reload_request),
         session_settings <- session_settings_patch(plugin_settings),
         pane_settings <- pane_settings_patch(plugin_settings),
         event <-
           plugin_settings_applied_event(
             reload_request,
             plugin_id,
             pane_id,
             session_pid,
             plugin_settings,
             session_settings,
             pane_settings,
             options
           ),
         :ok <- Journal.append(journal_path, event),
         {:ok, session_snapshot} <- Session.apply_settings(session_pid, session_settings),
         {:ok, pane_model, updated_pane} <-
           update_plugin_settings_pane(
             pane_model_pid,
             pane_id,
             plugin_id,
             plugin_settings,
             pane_settings,
             event
           ) do
      {:ok,
       %{
         status: :applied,
         plugin_id: plugin_id,
         session_pid: session_pid,
         session_alive?: Process.alive?(session_pid),
         session_snapshot: session_snapshot,
         pane_id: pane_id,
         pane_preserved?: before_pane.id == updated_pane.id,
         pane_model: pane_model,
         pane: updated_pane,
         event: event,
         journal_path: journal_path
       }}
    end
  end

  def apply_plugin_settings_reload(_runtime, _reload_request, _options) do
    {:error, :plugin_settings_reload_unavailable}
  end

  @doc """
  Merges dynamically discovered skills into the live command registry.

  The supervised registry remains the source of truth for the terminal command
  surface. Newly accepted skills are journaled as one registry update before the
  live registry is swapped in, preserving replay visibility for discovery.
  """
  @spec discover_dynamic_skills(map(), map() | [map()] | nil, keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def discover_dynamic_skills(runtime, skills, options \\ [])

  def discover_dynamic_skills(
        %{
          services: %{command_registry: command_registry_pid},
          journal: %{path: journal_path}
        },
        skills,
        options
      )
      when is_pid(command_registry_pid) and is_binary(journal_path) do
    options = Map.new(options)
    before_registry = Agent.get(command_registry_pid, & &1)

    with {:ok, updated_registry} <- CommandRegistry.add_dynamic_skills(before_registry, skills),
         update_event <-
           command_registry_update_event(before_registry, updated_registry, skills, options),
         :ok <- Journal.append(journal_path, update_event) do
      Agent.update(command_registry_pid, fn _registry -> updated_registry end)

      {:ok,
       %{
         registry: updated_registry,
         event: update_event,
         accepted_entries: accepted_command_entries(before_registry, updated_registry),
         duplicate_count_delta:
           Map.get(updated_registry, :duplicate_count, 0) -
             Map.get(before_registry, :duplicate_count, 0),
         journal_path: journal_path
       }}
    end
  end

  def discover_dynamic_skills(_runtime, _skills, _options) do
    {:error, :command_registry_unavailable}
  end

  @doc """
  Routes raw or already-normalized runtime events through the Elixir-owned event
  pipeline.

  Source events are normalized before journaling. Hook lifecycle events then
  update the hook lifecycle service as first-class hook events rather than
  falling into the generic log bucket.
  """
  @spec route_event(map(), map() | LifecycleEvent.t(), keyword() | map()) ::
          {:ok, map()} | {:error, map()}
  def route_event(runtime, source_event, options \\ [])

  def route_event(
        %{
          services: %{event_pipeline: event_pipeline_pid, hook_lifecycle: hook_lifecycle_pid},
          journal: %{path: journal_path}
        },
        source_event,
        options
      )
      when is_pid(event_pipeline_pid) and is_pid(hook_lifecycle_pid) and is_binary(journal_path) do
    context = route_event_context(event_pipeline_pid, options)

    with {:ok, events, _report} <-
           SourceTransportNormalizer.normalize([source_event], context: context),
         :ok <- append_journaled_events(journal_path, events) do
      event_pipeline = update_event_pipeline(event_pipeline_pid, events)
      hooks = update_hook_lifecycle(hook_lifecycle_pid, events)

      {:ok,
       %{
         events: events,
         event_pipeline: event_pipeline,
         hooks: hooks,
         journal_path: journal_path
       }}
    else
      {:error, reason} when is_map(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, %{status: :failed, reason: reason}}
    end
  end

  def route_event(_runtime, _source_event, _options) do
    {:error, %{status: :failed, reason: :runtime_event_pipeline_unavailable}}
  end

  @doc """
  Stops the runtime supervisor and reports whether all service processes exited.
  """
  @spec shutdown(map(), keyword() | map()) :: map()
  def shutdown(runtime, options \\ [])

  def shutdown(%{supervisor_pid: supervisor_pid, services: services} = runtime, options)
      when is_pid(supervisor_pid) and is_map(services) do
    options = Map.new(options)
    timeout_ms = Map.get(options, :timeout_ms, 1_000)
    service_pids = Map.to_list(services)
    supervisor_alive_before? = Process.alive?(supervisor_pid)

    stop(runtime)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_process_exit([supervisor_pid | Enum.map(service_pids, &elem(&1, 1))], deadline)

    leaked_services =
      service_pids
      |> Enum.filter(fn {_id, pid} -> Process.alive?(pid) end)
      |> Enum.map(fn {id, _pid} -> id end)
      |> Enum.sort()

    supervisor_alive_after? = Process.alive?(supervisor_pid)

    %{
      status:
        if(supervisor_alive_after? or leaked_services != [],
          do: :shutdown_incomplete,
          else: :shutdown_complete
        ),
      orderly?: not supervisor_alive_after? and leaked_services == [],
      supervisor_alive_before?: supervisor_alive_before?,
      supervisor_stopped?: not supervisor_alive_after?,
      service_count: map_size(services),
      services_stopped?: leaked_services == [],
      released_service_ids: services |> Map.keys() |> Enum.sort(),
      leaked_service_ids: leaked_services,
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end

  def shutdown(runtime, _options) do
    stop(runtime)

    %{
      status: :shutdown_skipped,
      orderly?: true,
      supervisor_alive_before?: false,
      supervisor_stopped?: true,
      service_count: 0,
      services_stopped?: true,
      released_service_ids: [],
      leaked_service_ids: [],
      checked_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp ensure_project_dir(project_dir) do
    if File.dir?(project_dir) do
      :ok
    else
      {:error,
       %{
         status: :unhealthy,
         healthy?: false,
         reason: {:missing_project_dir, project_dir}
       }}
    end
  end

  defp prepare_journal_path(context, project_dir) do
    journal_path =
      context
      |> Map.get(:journal_path, default_journal_path(project_dir, session_id(context)))
      |> Path.expand()

    case File.mkdir_p(Path.dirname(journal_path)) do
      :ok -> {:ok, journal_path}
      {:error, reason} -> {:error, unhealthy(:journal_unavailable, reason)}
    end
  end

  defp start_runtime_services(context, project_dir, journal_path) do
    registry_name = unique_registry_name()

    children = [
      Supervisor.child_spec({Registry, keys: :unique, name: registry_name},
        id: :runtime_registry
      ),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one},
        id: :transport_supervisor
      ),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :session_supervisor),
      Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: :child_supervisor),
      agent_child(:event_pipeline, event_pipeline_state(context.config)),
      agent_child(:pane_model, pane_model_state()),
      agent_child(:focus_state, focus_state()),
      agent_child(:plugin_registry, plugin_state(context)),
      Supervisor.child_spec(
        {ConfigWatcher, plugin_config_watcher_options(context, project_dir, journal_path)},
        id: :plugin_config_watcher
      ),
      agent_child(:command_registry, command_registry_state(context)),
      agent_child(:queued_notifications, queued_notification_state()),
      agent_child(:hook_lifecycle, hook_lifecycle_state()),
      agent_child(:wonder_tool, wonder_tool_state(project_dir, journal_path))
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, supervisor_pid} ->
        Process.unlink(supervisor_pid)
        {:ok, supervisor_pid, service_pids(supervisor_pid), registry_name}

      {:error, reason} ->
        {:error, unhealthy(:runtime_supervision_unavailable, reason)}
    end
  end

  defp agent_child(id, initial_state) do
    Supervisor.child_spec({Agent, fn -> initial_state end}, id: id)
  end

  defp service_pids(supervisor_pid) do
    supervisor_pid
    |> Supervisor.which_children()
    |> Enum.reduce(%{}, fn {id, pid, _type, _modules}, acc ->
      if id in @service_ids and is_pid(pid), do: Map.put(acc, id, pid), else: acc
    end)
  end

  defp service_statuses(services) do
    Map.new(@service_ids, fn service_id ->
      status =
        case Map.get(services, service_id) do
          pid when is_pid(pid) -> :ready
          _missing -> :missing
        end

      {service_id, status}
    end)
  end

  defp journal_state(journal_path) do
    %{
      path: journal_path,
      mode: :append_only_jsonl,
      replayable?: true,
      next_event_seq: 1,
      normalized_event_count: 0
    }
  end

  defp event_pipeline_state(config) do
    %{
      owner: :elixir_runtime,
      normalized_event_seq: 0,
      normalized_event_count: 0,
      events: [],
      generic_log_messages: [],
      transports: [:stdio, :sse, :streamable_http],
      mailbox_capacity: config.stream_mailbox_capacity,
      backpressure_threshold: config.stream_mailbox_backpressure_threshold,
      backpressure_behavior: config.stream_mailbox_backpressure_behavior,
      no_loss_policy: :journal_before_render
    }
  end

  defp pane_model_state do
    %{
      panes: %{
        parent: %{id: :parent, kind: :parent_session, visible?: true},
        children: %{id: :children, kind: :child_sessions, visible?: true},
        queue: %{id: :queue, kind: :queued_notifications, visible?: true},
        status: %{id: :status, kind: :runtime_status, visible?: true},
        wonder_tool: %{id: :wonder_tool, kind: :interaction_surface, visible?: true}
      },
      focused: :task_prompt,
      open: [:parent, :children, :queue, :status, :wonder_tool]
    }
  end

  defp focus_state do
    FocusState.new()
  end

  defp plugin_state(context) do
    parsed_config_state = parsed_plugin_config_state(Map.get(context, :plugin_config))

    Map.merge(
      %{
        status: :ready,
        official_plugins: Map.get(context, :official_plugins, []),
        third_party_plugins: Map.get(context, :third_party_plugins, []),
        trust_policy: :provenance_required,
        reload_boundary: :elixir_runtime
      },
      parsed_config_state
    )
  end

  defp plugin_config_watcher_state(services, project_dir) do
    case Map.get(services, :plugin_config_watcher) do
      pid when is_pid(pid) ->
        state = ConfigWatcher.state(pid)

        %{
          status: :ready,
          owner: :elixir_runtime,
          watcher_pid: pid,
          project_dir: state.project_dir,
          source_paths: state.source_paths,
          plugin_setting_paths: state.plugin_setting_paths,
          source_count: length(state.source_paths),
          plugin_setting_source_count: length(state.plugin_setting_paths),
          emitted_count: state.emitted_count,
          reload_request_type: :plugin_config_reload_requested,
          plugin_settings_reload_request_type: :plugin_settings_reload_requested,
          ui_restart_required?: false
        }

      _missing ->
        %{
          status: :missing,
          owner: :elixir_runtime,
          project_dir: project_dir,
          source_paths: [],
          plugin_setting_paths: [],
          source_count: 0,
          plugin_setting_source_count: 0,
          emitted_count: 0,
          reload_request_type: :plugin_config_reload_requested,
          plugin_settings_reload_request_type: :plugin_settings_reload_requested,
          ui_restart_required?: false
        }
    end
  end

  defp plugin_config_watcher_options(context, project_dir, journal_path) do
    [
      project_dir: project_dir,
      source_paths: Map.get(context, :plugin_config_source_paths, []),
      plugin_setting_paths: Map.get(context, :plugin_setting_paths, []),
      poll_interval_ms: Map.get(context, :plugin_config_watcher_poll_interval_ms, 1_000),
      journal_path: journal_path,
      watcher_id: "plugin-config-watcher-" <> session_id(context)
    ]
  end

  defp read_reloaded_plugin_config(reload_request, options) do
    source_path =
      reload_request
      |> value(:config_source_path)
      |> case do
        path when is_binary(path) -> path
        _missing -> Map.get(options, :config_source_path)
      end

    cond do
      not is_binary(source_path) ->
        {:invalid, nil, :missing_config_source_path}

      reload_request |> value(:change) == :deleted ->
        {:missing, source_path, :deleted}

      not File.regular?(source_path) ->
        {:missing, source_path, :not_found}

      true ->
        source_path
        |> parse_plugin_config_source(options)
        |> case do
          {:ok, plugin_config} -> {:ok, source_path, plugin_config}
          {:error, reason} -> {:invalid, source_path, reason}
        end
    end
  end

  defp parse_plugin_config_source(source_path, options) do
    project_dir =
      options
      |> Map.get(:project_dir, Path.dirname(source_path))
      |> Path.expand()

    with {:ok, %{data: data}} <- Config.parse_config_file(source_path, project_dir),
         {:ok, plugins} <- fetch_plugin_config_list(data) do
      %{"plugins" => plugins}
      |> Ourocode.Json.encode!()
      |> IO.iodata_to_binary()
      |> ConfigSchema.parse()
    end
  end

  defp fetch_plugin_config_list(%{"plugins" => plugins}) when is_list(plugins), do: {:ok, plugins}

  defp fetch_plugin_config_list(%{"plugins" => _plugins}) do
    {:error, {:invalid_plugin_config_schema, "plugins must be a list"}}
  end

  defp fetch_plugin_config_list(_data) do
    {:error, {:invalid_plugin_config_schema, "plugins list is required"}}
  end

  defp plugin_reload_state(
         {:ok, source_path, plugin_config},
         before_plugins,
         reload_request,
         options
       ) do
    reloaded_plugins =
      before_plugins
      |> Map.merge(parsed_plugin_config_state(plugin_config))
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

  defp plugin_reload_state(
         {:missing, source_path, reason},
         before_plugins,
         reload_request,
         options
       ) do
    missing_plugins =
      before_plugins
      |> Map.merge(parsed_plugin_config_state(nil))
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

  defp plugin_reload_state(
         {:invalid, source_path, reason},
         before_plugins,
         reload_request,
         options
       ) do
    invalid_plugins =
      before_plugins
      |> Map.merge(parsed_plugin_config_state(nil))
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

  defp reloaded_command_registry(:loaded, plugin_config, _before_commands) do
    {:ok, command_registry} = CommandRegistry.load(skill_dirs: [], plugin_config: plugin_config)
    command_registry
  end

  defp reloaded_command_registry(:missing, _plugin_config, _before_commands) do
    {:ok, command_registry} = CommandRegistry.load(skill_dirs: [], plugin_config: nil)
    command_registry
  end

  defp reloaded_command_registry(:invalid, _plugin_config, before_commands), do: before_commands

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

  defp plugin_config_reloaded_event(reload_request, plugins, options) do
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

  defp plugin_settings_plugin_id(reload_request, options) do
    case value(reload_request, :plugin_id) || Map.get(options, :plugin_id) do
      plugin_id when is_binary(plugin_id) and plugin_id != "" -> {:ok, plugin_id}
      _missing -> {:error, :missing_plugin_id}
    end
  end

  defp plugin_settings_session_pid(options) do
    case Map.get(options, :session_pid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :session_process_not_alive}

      _missing ->
        {:error, :missing_session_pid}
    end
  end

  defp plugin_settings_pane(pane_model_pid, options) do
    pane_id = Map.get(options, :pane_id)
    pane_model = Agent.get(pane_model_pid, & &1)
    panes = Map.get(pane_model, :panes, %{})

    case {pane_id, Map.get(panes, pane_id)} do
      {pane_id, %{id: ^pane_id} = pane} when is_binary(pane_id) -> {:ok, pane_id, pane}
      {pane_id, _pane} when is_binary(pane_id) -> {:error, {:pane_not_found, pane_id}}
      _missing -> {:error, :missing_pane_id}
    end
  end

  defp read_plugin_settings(reload_request) do
    case value(reload_request, :change) do
      :deleted ->
        {:ok, %{}}

      "deleted" ->
        {:ok, %{}}

      _change ->
        reload_request
        |> value(:settings_source_path)
        |> case do
          path when is_binary(path) -> decode_plugin_settings(path)
          _missing -> {:error, :missing_settings_source_path}
        end
    end
  end

  defp decode_plugin_settings(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Ourocode.Json.decode(contents),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      false -> {:error, :invalid_plugin_settings_schema}
      {:error, reason} -> {:error, {:invalid_plugin_settings, reason}}
    end
  end

  defp session_settings_patch(settings) do
    settings
    |> setting_map(:session_settings)
    |> case do
      nil -> setting_map(settings, :session) || %{}
      session_settings -> session_settings
    end
  end

  defp pane_settings_patch(settings) do
    settings
    |> setting_map(:pane_settings)
    |> case do
      nil -> setting_map(settings, :pane) || %{}
      pane_settings -> pane_settings
    end
  end

  defp setting_map(settings, key) when is_map(settings) do
    case value(settings, key) do
      map when is_map(map) -> map
      _missing_or_invalid -> nil
    end
  end

  defp plugin_settings_applied_event(
         reload_request,
         plugin_id,
         pane_id,
         session_pid,
         plugin_settings,
         session_settings,
         pane_settings,
         options
       ) do
    %{
      type: :plugin_settings_applied,
      event_type: :plugin_settings_applied,
      source: :plugin_registry,
      plugin_id: plugin_id,
      pane_id: pane_id,
      session_pid: inspect(session_pid),
      change: value(reload_request, :change),
      request_id: value(reload_request, :request_id),
      settings_source_path: value(reload_request, :settings_source_path),
      settings_source_relative_path: value(reload_request, :settings_source_relative_path),
      settings_source_signature: value(reload_request, :settings_source_signature),
      plugin_settings: plugin_settings,
      session_settings: session_settings,
      pane_settings: pane_settings,
      occurred_at_ms: Map.get(options, :occurred_at_ms, System.system_time(:millisecond)),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false
    }
  end

  defp update_plugin_settings_pane(
         pane_model_pid,
         pane_id,
         plugin_id,
         plugin_settings,
         pane_settings,
         event
       ) do
    Agent.get_and_update(pane_model_pid, fn pane_model ->
      panes = Map.get(pane_model, :panes, %{})

      case Map.get(panes, pane_id) do
        %{id: ^pane_id} = pane ->
          updated_pane =
            put_plugin_settings_on_pane(pane, plugin_id, plugin_settings, pane_settings, event)

          updated_model = %{pane_model | panes: Map.put(panes, pane_id, updated_pane)}
          {{:ok, updated_model, updated_pane}, updated_model}

        _missing ->
          {{:error, {:pane_not_found, pane_id}}, pane_model}
      end
    end)
  end

  defp put_plugin_settings_on_pane(pane, plugin_id, plugin_settings, pane_settings, event) do
    pane_state =
      pane
      |> Map.get(:pane_state, %{})
      |> Map.put(:plugin_settings, plugin_settings)
      |> Map.update(:plugin_settings_by_plugin, %{plugin_id => plugin_settings}, fn by_plugin ->
        Map.put(by_plugin, plugin_id, plugin_settings)
      end)
      |> Map.put(:plugin_pane_settings, pane_settings)
      |> Map.put(:last_plugin_settings_reload, %{
        plugin_id: plugin_id,
        request_id: event.request_id,
        change: event.change,
        occurred_at_ms: event.occurred_at_ms
      })

    %{pane | pane_state: pane_state, updated_at_ms: event.occurred_at_ms}
  end

  defp parsed_plugin_config_state(%ConfigSchema{plugins: plugins}) do
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

  defp parsed_plugin_config_state(_plugin_config) do
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

  defp command_registry_state(context) do
    {:ok, command_registry} =
      CommandRegistry.load(skill_dirs: [], plugin_config: Map.get(context, :plugin_config))

    Map.merge(command_registry, %{
      merged_sources: [:builtin, :bundled_skill, :local, :plugin, :mcp, :dynamic_skill],
      dedupe_policy: :source_priority_then_alias,
      slash_commands_loaded?: true,
      natural_language_input?: true
    })
  end

  defp queued_notification_state do
    %{
      status: :ready,
      items: [],
      overflow_policy: :journal_and_summarize,
      replayable?: true
    }
  end

  defp hook_lifecycle_state do
    %{
      status: :ready,
      visible_states: [:started, :progress, :response, :completed, :failed],
      events: [],
      event_count: 0,
      latest_started: nil,
      latest_progress: nil,
      latest_response: nil,
      latest_completed: nil,
      output_summary?: true,
      replayable?: true
    }
  end

  defp route_event_context(event_pipeline_pid, options) do
    options = Map.new(options)

    event_seq =
      Agent.get(event_pipeline_pid, fn event_pipeline ->
        Map.get(event_pipeline, :normalized_event_seq, 0) + 1
      end)

    %{
      event_seq: event_seq,
      parent_call_id: Map.get(options, :parent_call_id, "runtime-event-pipeline"),
      runtime_source: Map.get(options, :runtime_source, "terminal-runtime"),
      external_ids: Map.get(options, :external_ids, %{})
    }
    |> Map.merge(Map.get(options, :context, %{}))
  end

  defp append_journaled_events(journal_path, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case Journal.append(journal_path, event) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_event_pipeline(event_pipeline_pid, events) do
    Agent.get_and_update(event_pipeline_pid, fn event_pipeline ->
      updated =
        event_pipeline
        |> Map.update(:events, events, &(&1 ++ events))
        |> Map.update!(:normalized_event_count, &(&1 + length(events)))
        |> Map.put(:normalized_event_seq, latest_event_seq(events, event_pipeline))

      {updated, updated}
    end)
  end

  defp update_hook_lifecycle(hook_lifecycle_pid, events) do
    hook_events = Enum.filter(events, &hook_lifecycle_event?/1)

    Agent.get_and_update(hook_lifecycle_pid, fn hook_lifecycle ->
      updated =
        hook_lifecycle
        |> Map.update(:events, hook_events, &(&1 ++ hook_events))
        |> Map.update(:event_count, length(hook_events), &(&1 + length(hook_events)))
        |> maybe_put_latest_started(hook_events)
        |> maybe_put_latest_progress(hook_events)
        |> maybe_put_latest_response(hook_events)
        |> maybe_put_latest_completed(hook_events)

      {updated, updated}
    end)
  end

  defp latest_event_seq([], event_pipeline), do: Map.get(event_pipeline, :normalized_event_seq, 0)

  defp latest_event_seq(events, event_pipeline) do
    events
    |> Enum.map(&event_value(&1, :event_seq))
    |> Enum.filter(&is_integer/1)
    |> case do
      [] -> Map.get(event_pipeline, :normalized_event_seq, 0) + length(events)
      seqs -> Enum.max(seqs)
    end
  end

  defp maybe_put_latest_started(hook_lifecycle, hook_events) do
    hook_events
    |> Enum.filter(&(event_value(&1, :type) == :hook_started))
    |> List.last()
    |> case do
      nil -> hook_lifecycle
      event -> Map.put(hook_lifecycle, :latest_started, event)
    end
  end

  defp maybe_put_latest_progress(hook_lifecycle, hook_events) do
    hook_events
    |> Enum.filter(&(event_value(&1, :type) == :hook_progress))
    |> List.last()
    |> case do
      nil -> hook_lifecycle
      event -> Map.put(hook_lifecycle, :latest_progress, event)
    end
  end

  defp maybe_put_latest_response(hook_lifecycle, hook_events) do
    hook_events
    |> Enum.filter(&(event_value(&1, :type) == :hook_response))
    |> List.last()
    |> case do
      nil -> hook_lifecycle
      event -> Map.put(hook_lifecycle, :latest_response, event)
    end
  end

  defp maybe_put_latest_completed(hook_lifecycle, hook_events) do
    hook_events
    |> Enum.filter(&(event_value(&1, :type) == :hook_completed))
    |> List.last()
    |> case do
      nil -> hook_lifecycle
      event -> Map.put(hook_lifecycle, :latest_completed, event)
    end
  end

  defp hook_lifecycle_event?(event) do
    event_value(event, :type) in [:hook_started, :hook_progress, :hook_response, :hook_completed]
  end

  defp command_registry_update_event(before_registry, updated_registry, skills, options) do
    accepted_entries = accepted_command_entries(before_registry, updated_registry)

    %{
      type: :command_registry_updated,
      event_type: :command_registry_updated,
      source: :command_registry,
      occurred_at_ms: Map.get(options, :occurred_at_ms, System.system_time(:millisecond)),
      session_id: Map.get(options, :session_id),
      payload: %{
        reason: Map.get(options, :reason, :dynamic_skill_discovery),
        discovered_from: Map.get(options, :discovered_from, "dynamic_skill_discovery"),
        discovered_count: skills |> List.wrap() |> Enum.count(&is_map/1),
        accepted_count: length(accepted_entries),
        accepted_slashes: Enum.map(accepted_entries, & &1.slash),
        accepted_entries: Enum.map(accepted_entries, &command_registry_event_entry/1),
        sources: Map.get(updated_registry, :sources, []),
        loaded_count: Map.get(updated_registry, :loaded_count, 0),
        duplicate_count: Map.get(updated_registry, :duplicate_count, 0),
        duplicate_count_delta:
          Map.get(updated_registry, :duplicate_count, 0) -
            Map.get(before_registry, :duplicate_count, 0)
      }
    }
  end

  defp accepted_command_entries(before_registry, updated_registry) do
    before_slashes = before_registry |> Map.get(:entries, %{}) |> Map.keys() |> MapSet.new()

    updated_registry
    |> Map.get(:ordered, [])
    |> Enum.filter(
      &(&1.source == :dynamic_skill and not MapSet.member?(before_slashes, &1.slash))
    )
  end

  defp command_registry_event_entry(entry) do
    %{
      id: entry.id,
      name: entry.name,
      slash: entry.slash,
      aliases: entry.aliases,
      source: entry.source,
      source_id: entry.source_id,
      category: entry.category,
      availability: entry.availability,
      runnable?: entry.runnable?,
      run_spec: entry.run_spec
    }
  end

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp value(_map, _key, default), do: default

  defp event_value(%LifecycleEvent{} = event, key), do: Map.get(event, key)

  defp event_value(%{} = event, key),
    do: Map.get(event, key) || Map.get(event, Atom.to_string(key))

  defp wonder_tool_state(project_dir, journal_path) do
    %{
      status: :ready,
      surface: :terminal,
      supports: [:options, :other, :multi_select, :previews, :annotations],
      routing: :focused_session,
      project_dir: project_dir,
      journal_path: journal_path
    }
  end

  defp session_id(context) do
    Map.get_lazy(context, :runtime_session_id, fn ->
      "terminal-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end)
  end

  defp default_journal_path(project_dir, session_id) do
    Path.join([project_dir, ".ourocode", "journals", session_id <> ".jsonl"])
  end

  defp unique_registry_name do
    :"ourocode_runtime_registry_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unhealthy(reason, details) do
    %{
      status: :unhealthy,
      healthy?: false,
      reason: reason,
      details: details
    }
  end

  defp wait_for_process_exit(pids, deadline) do
    if Enum.any?(pids, &Process.alive?/1) and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      wait_for_process_exit(pids, deadline)
    else
      :ok
    end
  end
end
