defmodule Ourocode.Runtime.ApplicationStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.ApplicationState

  test "projects service statuses for all runtime service ids" do
    parent = self()

    ready_pid =
      spawn(fn ->
        send(parent, :ready)
        Process.sleep(:infinity)
      end)

    assert_receive :ready

    on_exit(fn ->
      if Process.alive?(ready_pid), do: Process.exit(ready_pid, :kill)
    end)

    statuses = ApplicationState.service_statuses(%{runtime_registry: ready_pid})

    assert statuses.runtime_registry == :ready
    assert statuses.command_registry == :missing
    assert Map.keys(statuses) |> Enum.sort() == ApplicationState.service_ids() |> Enum.sort()
  end

  test "builds bootstrap states without starting runtime services" do
    config = Ourocode.Config.defaults()
    journal_path = "/tmp/ourocode-runtime-state-test.jsonl"

    assert ApplicationState.journal_state(journal_path) == %{
             path: journal_path,
             mode: :append_only_jsonl,
             replayable?: true,
             next_event_seq: 1,
             normalized_event_count: 0
           }

    assert ApplicationState.event_pipeline_state(config).transports == [
             :stdio,
             :sse,
             :streamable_http
           ]

    assert ApplicationState.pane_model_state().open == [
             :parent,
             :children,
             :queue,
             :status,
             :wonder_tool
           ]

    assert ApplicationState.queued_notification_state().overflow_policy == :journal_and_summarize

    assert ApplicationState.hook_lifecycle_state().visible_states == [
             :started,
             :progress,
             :response,
             :completed,
             :failed
           ]

    assert ApplicationState.wonder_tool_state("/project", journal_path).supports == [
             :options,
             :other,
             :multi_select,
             :previews,
             :annotations
           ]
  end

  test "builds plugin watcher options from runtime bootstrap context" do
    options =
      ApplicationState.plugin_config_watcher_options(
        %{
          runtime_session_id: "terminal-state-test",
          plugin_config_source_paths: ["/project/.ourocode/config.json"],
          plugin_setting_paths: ["/project/plugins/settings.json"],
          plugin_config_watcher_poll_interval_ms: false
        },
        "/project",
        "/project/.ourocode/journals/session.jsonl"
      )

    assert options[:project_dir] == "/project"
    assert options[:source_paths] == ["/project/.ourocode/config.json"]
    assert options[:plugin_setting_paths] == ["/project/plugins/settings.json"]
    assert options[:poll_interval_ms] == false
    assert options[:watcher_id] == "plugin-config-watcher-terminal-state-test"
  end

  test "marks missing plugin watcher state without touching a process" do
    assert ApplicationState.plugin_config_watcher_state(%{}, "/project") == %{
             status: :missing,
             owner: :elixir_runtime,
             project_dir: "/project",
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
