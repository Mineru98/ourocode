defmodule Ourocode.Runtime.ApplicationTest do
  use ExUnit.Case, async: false

  alias Ourocode.Plugin.ConfigSchema
  alias Ourocode.Journal
  alias Ourocode.MCP.LifecycleEvent
  alias Ourocode.Runtime.Application
  alias Ourocode.Runtime.Stream.Session

  test "bootstrap starts required interactive terminal runtime services and state" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-runtime-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-test",
               journal_path: journal_path,
               official_plugins: ["ouroboros"],
               third_party_plugins: ["vim-mode"]
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert runtime.status == :ready
    assert runtime.healthy? == true
    assert runtime.session_id == "terminal-test"
    assert Process.alive?(runtime.supervisor_pid)

    assert runtime.journal == %{
             path: Path.expand(journal_path),
             mode: :append_only_jsonl,
             replayable?: true,
             next_event_seq: 1,
             normalized_event_count: 0
           }

    assert File.dir?(Path.dirname(journal_path))

    expected_services = [
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

    assert Enum.sort(Map.keys(runtime.services)) == Enum.sort(expected_services)
    assert Enum.all?(runtime.services, fn {_id, pid} -> Process.alive?(pid) end)

    assert Map.values(runtime.service_statuses) ==
             List.duplicate(:ready, length(expected_services))

    assert runtime.event_pipeline.transports == [:stdio, :sse, :streamable_http]
    assert runtime.event_pipeline.no_loss_policy == :journal_before_render
    assert runtime.pane_model.open == [:parent, :children, :queue, :status, :wonder_tool]
    assert runtime.focus_state.focused_pane == :task_prompt
    assert runtime.focus_state.steering_target == :parent
    assert runtime.plugins.official_plugins == ["ouroboros"]
    assert runtime.plugins.third_party_plugins == ["vim-mode"]
    assert runtime.plugin_config_watcher.status == :ready
    assert runtime.plugin_config_watcher.owner == :elixir_runtime
    assert runtime.plugin_config_watcher.reload_request_type == :plugin_config_reload_requested
    assert runtime.plugin_config_watcher.ui_restart_required? == false

    assert runtime.commands.merged_sources == [
             :builtin,
             :bundled_skill,
             :local,
             :plugin,
             :mcp,
             :dynamic_skill
           ]

    assert :bundled_skill in runtime.commands.sources
    assert Map.has_key?(runtime.commands.entries, "/wonder-tool")
    assert runtime.queued_notifications.replayable? == true
    assert runtime.hooks.visible_states == [:started, :progress, :response, :completed, :failed]

    assert runtime.wonder_tool.supports == [
             :options,
             :other,
             :multi_select,
             :previews,
             :annotations
           ]
  end

  test "bootstrap applies parsed plugin enabled and disabled config states" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-runtime-plugins-#{unique_id()}.jsonl")

    assert {:ok, plugin_config} =
             ConfigSchema.parse("""
             {
               "plugins": [
                 {
                   "identity": {"id": "ouroboros-plugin", "version": "0.1.0"},
                   "path": "plugins/ouroboros",
                   "entrypoint": {"type": "manifest", "path": "capabilities.json"},
                   "enabled": true,
                   "source": "official",
                   "permissions": {
                     "filesystem": ["plugins/ouroboros"],
                     "network": [],
                     "process": []
                   },
                   "config": {
                     "commands": true,
                     "skills": true
                   }
                 },
                 {
                   "identity": {"id": "vim-mode", "version": "1.0.0"},
                   "path": "plugins/vim-mode",
                   "entrypoint": {"type": "executable", "command": "bin/vim-mode"},
                   "enabled": false,
                   "permissions": {
                     "filesystem": [],
                     "network": [],
                     "process": ["bin/vim-mode"]
                   }
                 }
               ]
             }
             """)

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-plugin-state-test",
               journal_path: journal_path,
               plugin_config: plugin_config
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert runtime.plugins.config_loaded? == true
    assert runtime.plugins.enabled_plugins == ["ouroboros-plugin"]
    assert runtime.plugins.disabled_plugins == ["vim-mode"]

    assert runtime.plugins.plugins_by_id["ouroboros-plugin"].state == :enabled
    assert runtime.plugins.plugins_by_id["vim-mode"].state == :disabled
    assert runtime.commands.sources == [:builtin, :bundled_skill, :plugin]
    assert runtime.commands.entries["/ooo"].source == :plugin
    assert runtime.commands.entries["/ooo"].source_id == "ouroboros-plugin"
    assert runtime.commands.entries["/ouroboros-qa"].run_spec.kind == :plugin_skill

    assert runtime.plugins.load_transitions == [
             %{
               plugin_id: "ouroboros-plugin",
               from: :configured,
               to: :enabled,
               action: :load_requested,
               loadable?: true,
               reason: :enabled_in_config
             },
             %{
               plugin_id: "vim-mode",
               from: :configured,
               to: :disabled,
               action: :skip_load,
               loadable?: false,
               reason: :disabled_in_config
             }
           ]
  end

  test "plugin config reload handler re-reads config and updates enabled disabled invalid and missing status" do
    project_dir = tmp_project_dir!("runtime-plugin-config-reload")
    config_path = Path.join(project_dir, ".ourocode/config.json")
    journal_path = Path.join(project_dir, ".ourocode/journals/reload.jsonl")
    File.mkdir_p!(Path.dirname(config_path))
    File.mkdir_p!(Path.dirname(journal_path))

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-plugin-reload-test",
               journal_path: journal_path,
               plugin_config_source_paths: [config_path],
               plugin_config_watcher_poll_interval_ms: false
             })

    on_exit(fn ->
      Application.stop(runtime)
      File.rm_rf!(project_dir)
    end)

    File.write!(config_path, plugin_config_json(true, false))

    assert {:ok, loaded} =
             Application.handle_plugin_config_reload(
               runtime,
               reload_request(config_path, :created),
               occurred_at_ms: 10,
               project_dir: project_dir
             )

    assert loaded.status == :loaded
    assert loaded.plugins.status == :ready
    assert loaded.plugins.config_loaded? == true
    assert loaded.plugins.enabled_plugins == ["ouroboros-plugin"]
    assert loaded.plugins.disabled_plugins == ["vim-mode"]
    assert loaded.plugins.plugins_by_id["ouroboros-plugin"].state == :enabled
    assert loaded.plugins.plugins_by_id["vim-mode"].state == :disabled
    assert loaded.plugins.last_reload.ui_restart_required? == false
    assert loaded.commands.entries["/ooo"].source == :plugin

    assert {:ok, current_plugins} = Application.current_plugin_registry(runtime)
    assert current_plugins.enabled_plugins == ["ouroboros-plugin"]
    assert current_plugins.disabled_plugins == ["vim-mode"]

    File.write!(config_path, ~s({"plugins":"bad"}))

    assert {:ok, invalid} =
             Application.handle_plugin_config_reload(
               runtime,
               reload_request(config_path, :modified),
               occurred_at_ms: 20,
               project_dir: project_dir
             )

    assert invalid.status == :invalid
    assert invalid.plugins.status == :invalid
    assert invalid.plugins.config_invalid? == true

    assert invalid.plugins.config_error ==
             {:invalid_plugin_config_schema, "plugins must be a list"}

    assert invalid.plugins.enabled_plugins == []
    assert invalid.commands.entries["/ooo"].source == :plugin

    File.rm!(config_path)

    assert {:ok, missing} =
             Application.handle_plugin_config_reload(
               runtime,
               reload_request(config_path, :deleted),
               occurred_at_ms: 30,
               project_dir: project_dir
             )

    assert missing.status == :missing
    assert missing.plugins.status == :missing
    assert missing.plugins.config_missing? == true
    assert missing.plugins.config_error == :deleted
    assert missing.plugins.configured_plugins == []
    refute Map.has_key?(missing.commands.entries, "/ooo")

    assert {:ok, current_plugins} = Application.current_plugin_registry(runtime)
    assert current_plugins.status == :missing
    assert current_plugins.config_missing? == true

    assert {:ok, replayed} = Journal.read_ordered(journal_path)
    reload_events = Enum.filter(replayed, &(event_value(&1, :type) == :plugin_config_reloaded))

    assert Enum.map(reload_events, &(event_value(&1, :status) |> normalize_event_value())) == [
             :loaded,
             :invalid,
             :missing
           ]

    assert Enum.all?(
             reload_events,
             &(event_value(&1, :reload_boundary) |> normalize_event_value() == :elixir_runtime)
           )

    assert Enum.all?(reload_events, &(event_value(&1, :ui_restart_required?) == false))
  end

  test "dynamic skill discovery updates the live merged command surface and journals the change" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-dynamic-skills-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-dynamic-skill-test",
               journal_path: journal_path
             })

    on_exit(fn ->
      Application.stop(runtime)
      File.rm(journal_path)
    end)

    assert {:ok, before_registry} = Application.current_command_registry(runtime)
    assert before_registry.entries["/help"].source == :builtin
    assert before_registry.entries["/wonder-tool"].source == :bundled_skill
    refute Map.has_key?(before_registry.entries, "/session-diagnose")

    assert {:ok, result} =
             Application.discover_dynamic_skills(
               runtime,
               [
                 %{
                   id: "session-skill-diagnose",
                   name: "Session Diagnose",
                   description: "Inspect the focused session discovered at runtime.",
                   aliases: ["/diagnose-session"],
                   args: [
                     %{
                       name: "session_id",
                       required?: false,
                       description: "Session id to inspect"
                     }
                   ],
                   mcp_tool: "session_diagnose",
                   source_id: "parent-session",
                   discovered_from: "skill-index-refresh"
                 }
               ],
               occurred_at_ms: 123_456,
               session_id: runtime.session_id,
               discovered_from: "skill-index-refresh"
             )

    assert [%{slash: "/session-diagnose"} = accepted_entry] = result.accepted_entries
    assert accepted_entry.source == :dynamic_skill
    assert result.event.type == :command_registry_updated
    assert result.event.source == :command_registry
    assert result.event.payload.accepted_slashes == ["/session-diagnose"]
    assert result.event.payload.discovered_count == 1
    assert result.event.payload.accepted_count == 1

    assert {:ok, updated_registry} = Application.current_command_registry(runtime)
    assert updated_registry.loaded_count == before_registry.loaded_count + 1
    assert updated_registry.sources == [:builtin, :bundled_skill, :dynamic_skill]

    assert updated_registry.entries["/help"].source == :builtin
    assert updated_registry.entries["/wonder-tool"].source == :bundled_skill

    assert {:ok, discovered} =
             Ourocode.Command.Registry.fetch(updated_registry, "/session-diagnose")

    assert discovered.source == :dynamic_skill
    assert discovered.summary == "Inspect the focused session discovered at runtime."
    assert discovered.run_spec.mcp_tool == "session_diagnose"

    assert {:ok, alias_entry} =
             Ourocode.Command.Registry.fetch(updated_registry, "/diagnose-session")

    assert alias_entry.slash == "/session-diagnose"

    assert {:ok, [journaled_event]} = Journal.read_ordered(journal_path)
    assert journaled_event.type == :command_registry_updated
    assert journaled_event.source == :command_registry
    assert journaled_event.payload["accepted_slashes"] == ["/session-diagnose"]

    assert journaled_event.payload["accepted_entries"] |> hd() |> Map.fetch!("slash") ==
             "/session-diagnose"
  end

  test "routes normalized hook started lifecycle events as first-class runtime hook events" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-hook-started-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-hook-started-test",
               journal_path: journal_path
             })

    on_exit(fn ->
      Application.stop(runtime)
      File.rm(journal_path)
    end)

    source_event = %{
      "type" => "hook_started",
      "hook_id" => "hook-started-runtime-1",
      "source" => "hook_lifecycle",
      "timestamp_ms" => 91_001,
      "payload" => %{
        "hook" => "before_child_dispatch",
        "plugin_id" => "ouroboros-plugin",
        "args" => ["child-runtime-1"]
      }
    }

    assert {:ok, result} =
             Application.route_event(runtime, source_event,
               parent_call_id: "parent-hook-started-runtime-1",
               runtime_source: "terminal-runtime",
               external_ids: %{"session_id" => "session-hook-started-runtime-1"}
             )

    assert [%LifecycleEvent{} = event] = result.events
    assert event.type == :hook_started
    assert event.hook_id == "hook-started-runtime-1"
    assert event.source == :hook_lifecycle
    assert event.transport == :runtime
    assert event.parent_call_id == "parent-hook-started-runtime-1"
    assert event.runtime_source == "hook_lifecycle"
    assert event.external_ids == %{"session_id" => "session-hook-started-runtime-1"}
    assert event.occurred_at_ms == 91_001

    assert result.event_pipeline.normalized_event_count == 1
    assert result.event_pipeline.normalized_event_seq == event.event_seq
    assert result.event_pipeline.events == [event]
    assert result.event_pipeline.generic_log_messages == []

    assert result.hooks.event_count == 1
    assert result.hooks.events == [event]
    assert result.hooks.latest_started == event
    refute Map.has_key?(result.hooks, :generic_log_messages)

    assert {:ok, [replayed]} = Journal.read_ordered(journal_path)
    assert replayed.type == :hook_started
    assert replayed.hook_id == "hook-started-runtime-1"
    refute replayed.type in [:log, :generic_log, :log_message]
  end

  test "routes normalized hook progress lifecycle events as first-class runtime hook events" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-hook-progress-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-hook-progress-test",
               journal_path: journal_path
             })

    on_exit(fn ->
      Application.stop(runtime)
      File.rm(journal_path)
    end)

    progress_payload = %{
      "message" => "Plugin manifest loaded",
      "state" => "manifest_loaded",
      "plugin_id" => "third-party-vim"
    }

    normalized_event =
      LifecycleEvent.new(:hook_progress, %{
        event_seq: 1,
        hook_id: "hook-progress-runtime-1",
        source: :plugin_runtime,
        transport: :runtime,
        parent_call_id: "parent-hook-progress-runtime-1",
        runtime_source: "plugin_runtime",
        external_ids: %{"session_id" => "session-hook-progress-runtime-1"},
        occurred_at_ms: 92_001,
        payload: progress_payload,
        progress_state: "manifest_loaded",
        ordering_metadata: %{"phase_index" => 2, "phase_count" => 4},
        raw_event: %{
          "type" => "hook_progress",
          "hook_id" => "hook-progress-runtime-1",
          "source" => "plugin_runtime",
          "payload" => progress_payload
        }
      })

    assert {:ok, result} = Application.route_event(runtime, normalized_event)

    assert [%LifecycleEvent{} = event] = result.events
    assert event.type == :hook_progress
    assert event.hook_id == "hook-progress-runtime-1"
    assert event.source == :plugin_runtime
    assert event.transport == :runtime
    assert event.parent_call_id == "parent-hook-progress-runtime-1"
    assert event.runtime_source == "plugin_runtime"
    assert event.external_ids == %{"session_id" => "session-hook-progress-runtime-1"}
    assert event.progress_state == "manifest_loaded"
    assert event.ordering_metadata == %{"phase_index" => 2, "phase_count" => 4}

    assert result.event_pipeline.normalized_event_count == 1
    assert result.event_pipeline.normalized_event_seq == 1
    assert result.event_pipeline.events == [event]
    assert result.event_pipeline.generic_log_messages == []

    assert result.hooks.event_count == 1
    assert result.hooks.events == [event]
    assert result.hooks.latest_progress == event
    assert result.hooks.latest_started == nil
    refute Map.has_key?(result.hooks, :generic_log_messages)

    assert {:ok, [replayed]} = Journal.read_ordered(journal_path)
    assert replayed.type == :hook_progress
    assert replayed.hook_id == "hook-progress-runtime-1"
    assert replayed.progress_state == "manifest_loaded"
    refute replayed.type in [:log, :generic_log, :log_message]
  end

  test "routes normalized hook response lifecycle events as first-class runtime hook events" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-hook-response-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-hook-response-test",
               journal_path: journal_path
             })

    on_exit(fn ->
      Application.stop(runtime)
      File.rm(journal_path)
    end)

    response_result = %{
      "decision" => "continue",
      "plugin_id" => "ouroboros-plugin",
      "summary" => "hook response accepted"
    }

    normalized_event =
      LifecycleEvent.new(:hook_response, %{
        event_seq: 1,
        hook_id: "hook-response-runtime-1",
        source: :hook_lifecycle,
        transport: :runtime,
        parent_call_id: "parent-hook-response-runtime-1",
        runtime_source: "hook_lifecycle",
        external_ids: %{"session_id" => "session-hook-response-runtime-1"},
        occurred_at_ms: 93_001,
        payload: %{"summary" => "hook response accepted"},
        status: "ok",
        result: response_result,
        completion_metadata: %{"duration_ms" => 18},
        raw_event: %{
          "type" => "hook_response",
          "hook_id" => "hook-response-runtime-1",
          "source" => "hook_lifecycle",
          "result" => response_result
        }
      })

    assert {:ok, result} = Application.route_event(runtime, normalized_event)

    assert [%LifecycleEvent{} = event] = result.events
    assert event.type == :hook_response
    assert event.hook_id == "hook-response-runtime-1"
    assert event.source == :hook_lifecycle
    assert event.transport == :runtime
    assert event.parent_call_id == "parent-hook-response-runtime-1"
    assert event.runtime_source == "hook_lifecycle"
    assert event.external_ids == %{"session_id" => "session-hook-response-runtime-1"}
    assert event.status == "ok"
    assert event.result == response_result
    assert event.completion_metadata == %{"duration_ms" => 18}

    assert result.event_pipeline.normalized_event_count == 1
    assert result.event_pipeline.normalized_event_seq == 1
    assert result.event_pipeline.events == [event]
    assert result.event_pipeline.generic_log_messages == []

    assert result.hooks.event_count == 1
    assert result.hooks.events == [event]
    assert result.hooks.latest_response == event
    assert result.hooks.latest_started == nil
    assert result.hooks.latest_progress == nil
    assert result.hooks.latest_completed == nil
    refute Map.has_key?(result.hooks, :generic_log_messages)

    assert {:ok, [replayed]} = Journal.read_ordered(journal_path)
    assert replayed.type == :hook_response
    assert replayed.hook_id == "hook-response-runtime-1"
    assert replayed.result == response_result
    refute replayed.type in [:log, :generic_log, :log_message]
  end

  test "integration: plugin scoped settings update an active session and pane in place" do
    project_dir = tmp_project_dir!("runtime-plugin-settings-apply")
    settings_path = Path.join(project_dir, "plugins/vim-mode/settings.json")
    journal_path = Path.join(project_dir, ".ourocode/journals/plugin-settings-apply.jsonl")
    File.mkdir_p!(Path.dirname(settings_path))
    File.mkdir_p!(Path.dirname(journal_path))

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-plugin-settings-apply-test",
               journal_path: journal_path,
               plugin_setting_paths: [%{plugin_id: "vim-mode", path: settings_path}],
               plugin_config_watcher_poll_interval_ms: false
             })

    on_exit(fn ->
      Application.stop(runtime)
      File.rm_rf!(project_dir)
    end)

    assert {:ok, session_pid} =
             DynamicSupervisor.start_child(
               runtime.services.session_supervisor,
               {Session,
                [
                  id: :plugin_settings_session,
                  runtime_source: "terminal-runtime",
                  session_id: "session-plugin-settings-1",
                  transport: :stdio,
                  external_ids: %{"session_id" => "session-plugin-settings-1"},
                  stream_mailbox_capacity: 8,
                  stream_mailbox_backpressure_threshold: 4,
                  stream_mailbox_drain_interval_ms: :manual
                ]}
             )

    pane_id = "child-session:session-plugin-settings-1"

    Agent.update(runtime.services.pane_model, fn pane_model ->
      pane_model
      |> Map.update!(:panes, fn panes ->
        Map.put(panes, pane_id, %{
          id: pane_id,
          kind: :child_session,
          child_id: "session-plugin-settings-1",
          parent_call_id: "parent-plugin-settings-1",
          runtime_source: "terminal-runtime",
          transport: :stdio,
          external_ids: %{"session_id" => "session-plugin-settings-1"},
          pane_state: %{title: "Plugin settings target"},
          updated_at_ms: 1_000
        })
      end)
      |> Map.update!(:open, &(&1 ++ [pane_id]))
    end)

    before_session_pid = session_pid
    before_session_snapshot = Session.snapshot(session_pid)
    before_pane_model = Agent.get(runtime.services.pane_model, & &1)
    before_pane = before_pane_model.panes[pane_id]

    File.write!(
      settings_path,
      Ourocode.Json.encode!(%{
        "mode" => "insert",
        "session_settings" => %{
          "stream_mailbox_capacity" => 12,
          "stream_mailbox_backpressure_threshold" => 6,
          "operation_timeout_ms" => 45_000
        },
        "pane_settings" => %{
          "keymap" => "vim",
          "status_label" => "Insert"
        }
      })
    )

    assert {:ok, result} =
             Application.apply_plugin_settings_reload(
               runtime,
               plugin_settings_reload_request(settings_path, :modified),
               plugin_id: "vim-mode",
               session_pid: session_pid,
               pane_id: pane_id,
               occurred_at_ms: 12_345
             )

    assert result.status == :applied
    assert result.session_pid == before_session_pid
    assert result.session_alive? == true
    assert Process.alive?(before_session_pid)
    assert result.pane_preserved? == true
    assert result.pane.id == before_pane.id

    after_session_snapshot = Session.snapshot(session_pid)
    assert after_session_snapshot.session_id == before_session_snapshot.session_id
    assert after_session_snapshot.event_count == before_session_snapshot.event_count
    assert after_session_snapshot.stream_mailbox_capacity == 12
    assert after_session_snapshot.stream_mailbox_backpressure_threshold == 6
    assert after_session_snapshot.stream_operation_timeout_ms == 45_000

    after_pane_model = Agent.get(runtime.services.pane_model, & &1)
    assert Map.has_key?(after_pane_model.panes, pane_id)
    assert after_pane_model.panes[pane_id].id == pane_id
    assert after_pane_model.open == before_pane_model.open
    assert after_pane_model.panes[pane_id].pane_state.title == "Plugin settings target"

    assert after_pane_model.panes[pane_id].pane_state.plugin_settings_by_plugin["vim-mode"][
             "mode"
           ] == "insert"

    assert after_pane_model.panes[pane_id].pane_state.plugin_pane_settings == %{
             "keymap" => "vim",
             "status_label" => "Insert"
           }

    assert {:ok, [journaled]} = Journal.read_ordered(journal_path)
    assert journaled.type == :plugin_settings_applied
    assert journaled.plugin_id == "vim-mode"
    assert journaled.pane_id == pane_id
    assert journaled.reload_boundary == :elixir_runtime
    assert journaled.ui_restart_required? == false
    assert journaled.session_settings["stream_mailbox_capacity"] == 12
  end

  test "bootstrap rejects invalid runtime context" do
    assert {:error, result} = Application.bootstrap(%{project_dir: File.cwd!()})

    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.reason == :invalid_runtime_bootstrap_context
  end

  test "focus_pane updates the supervised focus state for a valid pane id" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-runtime-focus-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-focus-test",
               journal_path: journal_path
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert {:ok, result} = Application.focus_pane(runtime, :children, occurred_at_ms: 2_400)

    assert result.focus_state.focused_pane == :children
    assert result.focus_state.previous_focused_pane == :task_prompt
    assert result.focus_state.steering_target == :child
    assert result.event.focused_pane == :children
    assert result.event.previous_focused_pane == :task_prompt

    assert {:ok, current_focus_state} = Application.current_focus_state(runtime)
    assert current_focus_state.focused_pane == :children
  end

  test "current_focused_child_session resolves the supervised focused child session" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-focused-child-#{unique_id()}.jsonl")

    child_pane_id = "child-session:runtime-focused-bravo"

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-focused-child-test",
               journal_path: journal_path
             })

    on_exit(fn -> Application.stop(runtime) end)

    Agent.update(runtime.services.pane_model, fn pane_model ->
      pane_model
      |> Map.update!(:panes, fn panes ->
        Map.put(panes, child_pane_id, %{
          id: child_pane_id,
          kind: :child_session,
          child_id: "runtime-focused-bravo",
          parent_call_id: "parent-runtime-focused-child",
          runtime_source: "opencode",
          transport: :stdio,
          external_ids: %{"native_session_id" => "native-runtime-focused-bravo"}
        })
      end)
      |> Map.update!(:open, &(&1 ++ [child_pane_id]))
    end)

    assert {:ok, focus_result} =
             Application.focus_pane(runtime, child_pane_id, occurred_at_ms: 2_410)

    assert focus_result.focus_state.steering_target == :child
    assert focus_result.focus_state.steering_target_session_id == "runtime-focused-bravo"

    assert {:ok,
            %{
              pane_id: ^child_pane_id,
              session_id: "runtime-focused-bravo",
              child_id: "runtime-focused-bravo",
              kind: :child_session,
              pane: %{
                parent_call_id: "parent-runtime-focused-child",
                external_ids: %{"native_session_id" => "native-runtime-focused-bravo"}
              }
            }} = Application.current_focused_child_session(runtime)
  end

  test "focus_pane leaves supervised focus state unchanged for an unknown pane id" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-focus-missing-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-focus-missing-test",
               journal_path: journal_path
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert {:ok, before_focus_state} = Application.current_focus_state(runtime)

    assert {:error, {:unknown_pane, "missing-pane"}} =
             Application.focus_pane(runtime, "missing-pane")

    assert {:ok, after_focus_state} = Application.current_focus_state(runtime)
    assert after_focus_state == before_focus_state
  end

  test "focus_pane does not emit a supervised event when focus is unchanged" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-focus-noop-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-focus-noop-test",
               journal_path: journal_path
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert {:ok, focused_result} =
             Application.focus_pane(runtime, :children, occurred_at_ms: 2_425)

    assert {:ok, noop_result} =
             Application.focus_pane(runtime, "children", occurred_at_ms: 2_525)

    assert noop_result.event == nil
    assert noop_result.focus_state == focused_result.focus_state
    assert noop_result.focus_state.history == [focused_result.event]
    assert noop_result.focus_state.focused_at_ms == 2_425
  end

  test "focus_pane rejects an unknown pane id without replacing the active focus" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-focus-reject-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-focus-reject-test",
               journal_path: journal_path
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert {:ok, focused_result} =
             Application.focus_pane(runtime, :children, occurred_at_ms: 2_450)

    assert {:error, {:unknown_pane, "missing-pane"}} =
             Application.focus_pane(runtime, "missing-pane", occurred_at_ms: 2_550)

    assert {:ok, after_focus_state} = Application.current_focus_state(runtime)
    assert after_focus_state == focused_result.focus_state
    assert after_focus_state.focused_pane == :children
    assert after_focus_state.previous_focused_pane == :task_prompt
    assert after_focus_state.steering_target == :child
    assert after_focus_state.focused_at_ms == 2_450
    assert after_focus_state.history == [focused_result.event]
  end

  test "focus_pane leaves supervised focus state unchanged for a closed pane id" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-runtime-focus-closed-#{unique_id()}.jsonl")

    assert {:ok, runtime} =
             Application.bootstrap(%{
               project_dir: project_dir,
               config: Ourocode.Config.defaults(),
               runtime_session_id: "terminal-focus-closed-test",
               journal_path: journal_path
             })

    on_exit(fn -> Application.stop(runtime) end)

    assert {:ok, focused_result} =
             Application.focus_pane(runtime, :children, occurred_at_ms: 2_700)

    Agent.update(runtime.services.pane_model, fn pane_model ->
      Map.put(pane_model, :open, [:parent, :queue, :status, :wonder_tool])
    end)

    assert {:error, {:unknown_pane, :children}} =
             Application.focus_pane(runtime, :children, occurred_at_ms: 2_800)

    assert {:ok, after_focus_state} = Application.current_focus_state(runtime)
    assert after_focus_state == focused_result.focus_state
    assert after_focus_state.focused_pane == :children
    assert after_focus_state.focused_at_ms == 2_700
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp reload_request(config_path, change) do
    %{
      type: :plugin_config_reload_requested,
      event_type: :plugin_config_reload_requested,
      source: :plugin_config_watcher,
      change: change,
      reason: :plugin_config_source_changed,
      config_source_path: Path.expand(config_path),
      config_source_relative_path: ".ourocode/config.json",
      occurred_at_ms: System.system_time(:millisecond),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false,
      request_id: "reload-#{change}"
    }
  end

  defp plugin_settings_reload_request(settings_path, change) do
    %{
      type: :plugin_settings_reload_requested,
      event_type: :plugin_settings_reload_requested,
      source: :plugin_config_watcher,
      plugin_id: "vim-mode",
      change: change,
      reason: :plugin_scoped_settings_changed,
      settings_source_path: Path.expand(settings_path),
      settings_source_relative_path: "plugins/vim-mode/settings.json",
      occurred_at_ms: System.system_time(:millisecond),
      reload_boundary: :elixir_runtime,
      ui_restart_required?: false,
      request_id: "plugin-settings-#{change}"
    }
  end

  defp plugin_config_json(official_enabled?, vim_enabled?) do
    Ourocode.Json.encode!(%{
      "plugins" => [
        %{
          "identity" => %{"id" => "ouroboros-plugin", "version" => "0.1.0"},
          "path" => "plugins/ouroboros",
          "entrypoint" => %{"type" => "manifest", "path" => "capabilities.json"},
          "enabled" => official_enabled?,
          "source" => "official",
          "permissions" => %{
            "filesystem" => ["plugins/ouroboros"],
            "network" => [],
            "process" => []
          },
          "config" => %{"commands" => true, "skills" => true}
        },
        %{
          "identity" => %{"id" => "vim-mode", "version" => "1.0.0"},
          "path" => "plugins/vim-mode",
          "entrypoint" => %{"type" => "executable", "command" => "bin/vim-mode"},
          "enabled" => vim_enabled?,
          "permissions" => %{
            "filesystem" => [],
            "network" => [],
            "process" => ["bin/vim-mode"]
          }
        }
      ]
    })
  end

  defp tmp_project_dir!(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ourocode-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  defp event_value(event, key) do
    if Map.has_key?(event, key),
      do: Map.get(event, key),
      else: Map.get(event, Atom.to_string(key))
  end

  defp normalize_event_value(value) when is_binary(value), do: String.to_existing_atom(value)
  defp normalize_event_value(value), do: value
end
