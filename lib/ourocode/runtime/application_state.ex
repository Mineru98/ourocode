defmodule Ourocode.Runtime.ApplicationState do
  @moduledoc """
  Pure state projections used while bootstrapping the interactive runtime.
  """

  alias Ourocode.Command.Registry, as: CommandRegistry
  alias Ourocode.Plugin.ConfigWatcher
  alias Ourocode.Runtime.FocusState
  alias Ourocode.Runtime.PluginConfigReload

  @service_ids [
    :runtime_registry,
    :transport_supervisor,
    :session_supervisor,
    :child_supervisor,
    :event_pipeline,
    :pane_model,
    :focus_state,
    :plugin_registry,
    :user_level_plugin_registry,
    :plugin_config_watcher,
    :command_registry,
    :queued_notifications,
    :hook_lifecycle,
    :wonder_tool
  ]

  @spec service_ids() :: [atom()]
  def service_ids, do: @service_ids

  @spec service_statuses(map()) :: map()
  def service_statuses(services) do
    Map.new(@service_ids, fn service_id ->
      status =
        case Map.get(services, service_id) do
          pid when is_pid(pid) -> :ready
          _missing -> :missing
        end

      {service_id, status}
    end)
  end

  @spec journal_state(Path.t()) :: map()
  def journal_state(journal_path) do
    %{
      path: journal_path,
      mode: :append_only_jsonl,
      replayable?: true,
      next_event_seq: 1,
      normalized_event_count: 0
    }
  end

  @spec event_pipeline_state(map()) :: map()
  def event_pipeline_state(config) do
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

  @spec pane_model_state() :: map()
  def pane_model_state do
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

  @spec focus_state() :: map()
  def focus_state do
    FocusState.new()
  end

  @spec plugin_state(map()) :: map()
  def plugin_state(context) do
    parsed_config_state = PluginConfigReload.config_state(Map.get(context, :plugin_config))

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

  @spec plugin_config_watcher_state(map(), Path.t()) :: map()
  def plugin_config_watcher_state(services, project_dir) do
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

  @spec plugin_config_watcher_options(map(), Path.t(), Path.t()) :: keyword()
  def plugin_config_watcher_options(context, project_dir, journal_path) do
    [
      project_dir: project_dir,
      source_paths: Map.get(context, :plugin_config_source_paths, []),
      plugin_setting_paths: Map.get(context, :plugin_setting_paths, []),
      poll_interval_ms: Map.get(context, :plugin_config_watcher_poll_interval_ms, 1_000),
      journal_path: journal_path,
      watcher_id: "plugin-config-watcher-" <> Map.fetch!(context, :runtime_session_id)
    ]
  end

  @spec command_registry_state(map()) :: map()
  def command_registry_state(context) do
    {:ok, command_registry} =
      CommandRegistry.load(skill_dirs: [], plugin_config: Map.get(context, :plugin_config))

    Map.merge(command_registry, %{
      merged_sources: [:builtin, :bundled_skill, :local, :plugin, :mcp, :dynamic_skill],
      dedupe_policy: :source_priority_then_alias,
      slash_commands_loaded?: true,
      natural_language_input?: true
    })
  end

  @spec queued_notification_state() :: map()
  def queued_notification_state do
    %{
      status: :ready,
      items: [],
      overflow_policy: :journal_and_summarize,
      replayable?: true
    }
  end

  @spec hook_lifecycle_state() :: map()
  def hook_lifecycle_state do
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

  @spec wonder_tool_state(Path.t(), Path.t()) :: map()
  def wonder_tool_state(project_dir, journal_path) do
    %{
      status: :ready,
      surface: :terminal,
      supports: [:options, :other, :multi_select, :previews, :annotations],
      routing: :focused_session,
      project_dir: project_dir,
      journal_path: journal_path
    }
  end
end
