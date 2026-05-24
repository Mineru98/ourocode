defmodule Ourocode.Runtime.Application do
  @moduledoc """
  Runtime bootstrap boundary for one interactive terminal session.

  Elixir owns the runtime state for the terminal app, so bootstrap starts the
  small OTP service set that later panes, transports, plugins, hooks, command
  discovery, wonderTool, and replay work can attach to.
  """

  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.ApplicationAccess
  alias Ourocode.Runtime.ApplicationBootstrap
  alias Ourocode.Runtime.ApplicationState
  alias Ourocode.Runtime.ApplicationShutdown
  alias Ourocode.Runtime.ApplicationServices
  alias Ourocode.Runtime.DynamicSkillDiscovery
  alias Ourocode.Runtime.EventRouter
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Runtime.PluginConfigReload
  alias Ourocode.Runtime.PluginSettingsReload

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
    session_id = ApplicationBootstrap.session_id(context)
    context = Map.put(context, :runtime_session_id, session_id)

    with {:ok, prepared} <- ApplicationBootstrap.prepare(context, project_dir),
         {:ok, supervisor_pid, services, registry_name} <-
           ApplicationServices.start(context, prepared.project_dir, prepared.journal_path) do
      {:ok,
       %{
         status: :ready,
         healthy?: true,
         session_id: session_id,
         supervisor_pid: supervisor_pid,
         services: services,
         service_statuses: ApplicationState.service_statuses(services),
         registry_name: registry_name,
         journal: ApplicationState.journal_state(prepared.journal_path),
         event_pipeline: ApplicationState.event_pipeline_state(config),
         pane_model: ApplicationState.pane_model_state(),
         focus_state: ApplicationState.focus_state(),
         plugins: ApplicationState.plugin_state(context),
         plugin_config_watcher:
           ApplicationState.plugin_config_watcher_state(services, prepared.project_dir),
         commands: ApplicationState.command_registry_state(context),
         queued_notifications: ApplicationState.queued_notification_state(),
         hooks: ApplicationState.hook_lifecycle_state(),
         wonder_tool:
           ApplicationState.wonder_tool_state(prepared.project_dir, prepared.journal_path)
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
  def stop(runtime), do: ApplicationShutdown.stop(runtime)

  @doc """
  Requests focus for a pane id known to the runtime pane model.
  """
  @spec focus_pane(map(), FocusState.pane_id(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def focus_pane(runtime, pane_id, options \\ [])

  def focus_pane(runtime, pane_id, options),
    do: ApplicationAccess.focus_pane(runtime, pane_id, options)

  @doc """
  Reads the current runtime focus state.
  """
  @spec current_focus_state(map()) :: {:ok, map()} | {:error, :focus_state_unavailable}
  def current_focus_state(runtime), do: ApplicationAccess.current_focus_state(runtime)

  @doc """
  Resolves the concrete child session currently targeted by runtime focus.
  """
  @spec current_focused_child_session(map()) ::
          {:ok, FocusState.focused_child_session()}
          | {:error,
             :no_focused_child_session
             | :focused_child_session_pane_not_found
             | :focus_state_unavailable}
  def current_focused_child_session(runtime),
    do: ApplicationAccess.current_focused_child_session(runtime)

  @doc """
  Reads the current supervised command registry.
  """
  @spec current_command_registry(map()) :: {:ok, map()} | {:error, :command_registry_unavailable}
  def current_command_registry(runtime), do: ApplicationAccess.current_command_registry(runtime)

  @doc """
  Reads the current supervised plugin registry/status record.
  """
  @spec current_plugin_registry(map()) :: {:ok, map()} | {:error, :plugin_registry_unavailable}
  def current_plugin_registry(runtime), do: ApplicationAccess.current_plugin_registry(runtime)

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
    PluginConfigReload.handle(
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

  def apply_plugin_settings_reload(runtime, reload_request, options) do
    PluginSettingsReload.apply(runtime, reload_request, options)
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
        runtime,
        skills,
        options
      ) do
    DynamicSkillDiscovery.discover(runtime, skills, options)
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
        runtime,
        source_event,
        options
      ) do
    EventRouter.route(runtime, source_event, options)
  end

  @doc """
  Stops the runtime supervisor and reports whether all service processes exited.
  """
  @spec shutdown(map(), keyword() | map()) :: map()
  def shutdown(runtime, options \\ [])

  def shutdown(runtime, options), do: ApplicationShutdown.shutdown(runtime, options)
end
