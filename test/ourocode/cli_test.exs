defmodule Ourocode.CLITest.DashboardSpy do
  def init(context) do
    send(Application.fetch_env!(:ourocode, :cli_test_pid), {:dashboard_init, context})
    {:ok, %{context: context}}
  end
end

defmodule Ourocode.CLITest.TerminalBootstrapSpy do
  def bootstrap(context) do
    send(Application.fetch_env!(:ourocode, :cli_test_pid), {:terminal_bootstrap, context})
    {:ok, %{context: context, terminal_bootstrap?: true}}
  end
end

defmodule Ourocode.CLITest.InteractiveTerminalSpy do
  def bootstrap(context) do
    Ourocode.Dashboard.Application.init(context)
  end
end

defmodule Ourocode.CLITest.StartupHangRuntime do
  def bootstrap(_context) do
    receive do
    after
      :infinity -> :ok
    end
  end

  def shutdown(_runtime, _options), do: :ok
end

defmodule Ourocode.CLITest.ShutdownHangRuntime do
  def bootstrap(context) do
    journal_path = Map.fetch!(context, :journal_path)

    {:ok,
     %{
       status: :ready,
       healthy?: true,
       session_id: Map.get(context, :runtime_session_id, "shutdown-hang-runtime"),
       services: %{},
       service_statuses: %{},
       journal: %{
         path: journal_path,
         mode: :append_only_jsonl,
         replayable?: true,
         next_event_seq: 1,
         normalized_event_count: 0
       },
       event_pipeline: %{transports: [:stdio, :sse, :streamable_http]},
       pane_model: %{open: [:parent, :children, :queue, :status, :wonder_tool]},
       focus_state: %{route: :terminal_input_loop},
       plugins: %{status: :ready},
       commands: %{slash_commands_loaded?: true, natural_language_input?: true},
       queued_notifications: %{replayable?: true},
       hooks: %{output_summary?: true},
       wonder_tool: %{surface: :terminal}
     }}
  end

  def shutdown(_runtime, _options) do
    receive do
    after
      :infinity -> :ok
    end
  end
end

defmodule Ourocode.CLITest do
  use ExUnit.Case, async: false

  alias Ourocode.CLI.StartupArgs
  alias Ourocode.CLI.SmokeTest

  import ExUnit.CaptureIO

  test "startup resolves the fixed implementation project directory" do
    assert Ourocode.CLI.resolve_project_dir() ==
             {:ok, "/Users/jaegyu.lee/Project/ourocode"}
  end

  test "startup argument parser separates launch args, config overrides, and task text" do
    project_dir = File.cwd!()

    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--parallel-child-count",
               "5",
               "--project-dir",
               project_dir,
               "--repeat-count=2",
               "Investigate",
               "pane",
               "routing"
             ])

    assert startup_args.project_dir == Path.expand(project_dir)
    assert startup_args.smoke_test? == false
    assert startup_args.config_args == ["--parallel-child-count", "5", "--repeat-count=2"]
    assert startup_args.task_request.task_input == "Investigate pane routing"
  end

  test "startup argument parser selects smoke test mode before task text" do
    assert {:ok, startup_args} =
             StartupArgs.parse([
               "--smoke-test",
               "--project-dir",
               File.cwd!(),
               "Check",
               "startup"
             ])

    assert startup_args.project_dir == File.cwd!()
    assert startup_args.smoke_test? == true
    assert startup_args.task_request.task_input == "Check startup"
  end

  test "startup invokes the dashboard initializer with resolved project context" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main([], Ourocode.CLITest.DashboardSpy)

    assert_receive {:dashboard_init, ^context}
    assert context.project_dir == "/Users/jaegyu.lee/Project/ourocode"
    assert is_binary(context.cwd)
    assert context.initial_task_request == nil

    assert context.config == %{
             parallel_child_count: 3,
             repeat_count: 1,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 64,
               stale_cleanup_timeout_ms: 30_000,
               stream_subscription_cleanup_timeout_ms: 10_000,
               pane_state_retention_ms: 300_000
             }
           }
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup invokes the terminal application bootstrap with parsed startup args" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, %{context: context, terminal_bootstrap?: true}} =
             Ourocode.CLI.main(
               ["--project-dir", File.cwd!(), "Review", "streaming", "status"],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert_receive {:terminal_bootstrap, ^context}
    assert context.project_dir == File.cwd!()
    assert context.initial_task_request.task_input == "Review streaming status"
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup loads project plugin config into terminal context" do
    Application.put_env(:ourocode, :cli_test_pid, self())
    project_dir = tmp_project_dir!("cli-plugin-config")
    File.mkdir_p!(Path.join(project_dir, ".ourocode"))

    File.write!(
      Path.join(project_dir, ".ourocode/config.json"),
      plugin_config_json()
    )

    assert {:ok, %{context: context, terminal_bootstrap?: true}} =
             Ourocode.CLI.main(
               ["--project-dir", project_dir],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert_receive {:terminal_bootstrap, ^context}
    assert context.project_dir == project_dir
    assert context.plugin_config.plugins |> Enum.map(& &1.id) == ["ouroboros-plugin"]
  after
    Application.delete_env(:ourocode, :cli_test_pid)
    cleanup_tmp_project_dir()
  end

  test "smoke test flag returns a non-interactive result without bootstrapping terminal UI" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, result} =
             Ourocode.CLI.main(
               ["--smoke-test", "--project-dir", File.cwd!(), "Smoke", "startup"],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert result.mode == :smoke_test
    assert result.status == :healthy
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false
    assert result.runtime.status == :ready
    assert result.runtime.journal.normalized_event_count >= 1
    assert result.checks.runtime_initialized? == true
    assert result.checks.core_interaction_endpoint_free? == true
    assert result.checks.startup_state_recorded? == true
    assert result.checks.journal_replayable? == true
    assert result.context.project_dir == File.cwd!()
    assert result.context.initial_task_request.task_input == "Smoke startup"
    assert result.checks.project_dir_exists? == true
    assert result.checks.config_loaded? == true
    assert result.checks.task_request_accepted? == true

    refute_receive {:terminal_bootstrap, _context}, 50
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "smoke test mode initializes minimal runtime services and journals startup state" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-smoke-#{unique_id()}.jsonl")
    File.rm(journal_path)

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:initial_task_request, %Ourocode.TaskRequest{
        source: :cli,
        task_input: "Smoke startup state",
        routing_decision: %{
          kind: :mcp_flow,
          execution_route: :mcp_flow,
          requires_command_syntax?: false
        }
      })
      |> Map.put(:runtime_session_id, "smoke-runtime-test")
      |> Map.put(:journal_path, journal_path)

    assert {:ok, result} = SmokeTest.run(context, output: :silent)

    assert result.mode == :smoke_test
    assert result.status == :healthy
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false

    assert result.runtime.status == :ready
    assert result.runtime.session_id == "smoke-runtime-test"
    assert result.runtime.service_statuses.runtime_registry == :ready
    assert result.runtime.service_statuses.event_pipeline == :ready
    assert result.runtime.service_statuses.command_registry == :ready
    assert result.runtime.service_statuses.wonder_tool == :ready
    assert result.shutdown.status == :shutdown_complete
    assert result.shutdown.orderly? == true
    assert result.shutdown.supervisor_alive_before? == true
    assert result.shutdown.supervisor_stopped? == true
    assert result.shutdown.services_stopped? == true
    assert result.shutdown.leaked_service_ids == []
    assert result.runtime.event_pipeline.transports == [:stdio, :sse, :streamable_http]
    assert result.runtime.pane_model.open == [:parent, :children, :queue, :status, :wonder_tool]
    assert result.runtime.focus_state.route == :terminal_input_loop
    assert result.runtime.commands.slash_commands_loaded? == true
    assert result.runtime.commands.natural_language_input? == true
    assert result.runtime.queued_notifications.replayable? == true
    assert result.runtime.hooks.output_summary? == true
    assert result.runtime.wonder_tool.surface == :terminal
    assert result.core_interaction_config_guard.status == :terminal_core_endpoint_free
    assert result.core_interaction_config_guard.core_interaction_requires_endpoint? == false

    assert result.checks == %{
             project_dir_exists?: true,
             config_loaded?: true,
             core_interaction_endpoint_free?: true,
             runtime_initialized?: true,
             runtime_shutdown?: true,
             startup_state_recorded?: true,
             journal_replayable?: true,
             task_request_accepted?: true
           }

    assert {:ok, [startup_event]} = Ourocode.Journal.read_ordered(journal_path)
    assert startup_event.event_seq == 1
    assert startup_event.type == :runtime_startup_succeeded
    assert startup_event.source == :cli
    assert startup_event.session_id == "smoke-runtime-test"

    assert startup_event.payload["initialized_services"] ==
             Enum.map(result.runtime.services, &Atom.to_string/1)

    assert startup_event.payload["project_dir"] == project_dir
    assert startup_event.payload["event_pipeline"]["no_loss_policy"] == "journal_before_render"

    assert startup_event.payload["core_interaction_config_guard"][
             "core_interaction_requires_endpoint?"
           ] == false
  end

  test "smoke test mode performs orderly shutdown and releases runtime resources" do
    project_dir = File.cwd!()
    journal_path = Path.join(System.tmp_dir!(), "ourocode-smoke-shutdown-#{unique_id()}.jsonl")
    File.rm(journal_path)

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:runtime_session_id, "smoke-shutdown-test")
      |> Map.put(:journal_path, journal_path)

    assert {:ok, result} = SmokeTest.run(context, output: :silent)

    assert result.status == :healthy

    assert result.shutdown == %{
             status: :shutdown_complete,
             orderly?: true,
             supervisor_alive_before?: true,
             supervisor_stopped?: true,
             service_count: 13,
             services_stopped?: true,
             released_service_ids: [
               :child_supervisor,
               :command_registry,
               :event_pipeline,
               :focus_state,
               :hook_lifecycle,
               :pane_model,
               :plugin_config_watcher,
               :plugin_registry,
               :queued_notifications,
               :runtime_registry,
               :session_supervisor,
               :transport_supervisor,
               :wonder_tool
             ],
             leaked_service_ids: [],
             checked_at_ms: result.shutdown.checked_at_ms
           }

    assert result.checks.runtime_shutdown? == true
    assert {:ok, [_startup_event]} = Ourocode.Journal.read_ordered(journal_path)
  end

  test "smoke test mode times out deterministically when runtime startup hangs" do
    project_dir = File.cwd!()

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:runtime_session_id, "smoke-startup-timeout-test")
      |> Map.put(
        :journal_path,
        Path.join(System.tmp_dir!(), "ourocode-smoke-startup-timeout-#{unique_id()}.jsonl")
      )

    started_at = System.monotonic_time(:millisecond)

    assert {:error, result} =
             SmokeTest.run(context,
               output: :silent,
               runtime_application: Ourocode.CLITest.StartupHangRuntime,
               timeout_ms: 25
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 1_000
    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.mode == :smoke_test
    assert result.reason == :smoke_test_timeout
    assert result.phase == :startup
    assert result.timeout_ms == 25
    assert result.deterministic_failure? == true
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false
    assert result.checks.runtime_initialized? == false
    assert result.checks.runtime_shutdown? == false
    assert result.checks.startup_state_recorded? == false
  end

  test "smoke test mode times out deterministically when runtime shutdown hangs" do
    project_dir = File.cwd!()

    journal_path =
      Path.join(System.tmp_dir!(), "ourocode-smoke-shutdown-timeout-#{unique_id()}.jsonl")

    File.rm(journal_path)

    context =
      project_dir
      |> Ourocode.CLI.project_context(Ourocode.Config.defaults())
      |> Map.put(:runtime_session_id, "smoke-shutdown-timeout-test")
      |> Map.put(:journal_path, journal_path)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, result} =
             SmokeTest.run(context,
               output: :silent,
               runtime_application: Ourocode.CLITest.ShutdownHangRuntime,
               timeout_ms: 25
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 1_000
    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.reason == :smoke_test_timeout
    assert result.phase == :shutdown
    assert result.timeout_ms == 25
    assert result.deterministic_failure? == true
    assert result.runtime.status == :ready
    assert result.runtime.session_id == "smoke-shutdown-timeout-test"
    assert result.checks.runtime_initialized? == true
    assert result.checks.runtime_shutdown? == false
    assert result.checks.startup_state_recorded? == true
    assert result.checks.journal_replayable? == true

    assert {:ok, [startup_event]} = Ourocode.Journal.read_ordered(journal_path)
    assert startup_event.type == :runtime_startup_succeeded
    assert startup_event.session_id == "smoke-shutdown-timeout-test"
  end

  test "smoke test can be selected from startup config without bootstrapping terminal UI" do
    original_smoke_test = Application.get_env(:ourocode, :smoke_test)

    on_exit(fn ->
      restore_env(:smoke_test, original_smoke_test)
    end)

    Application.put_env(:ourocode, :cli_test_pid, self())
    Application.put_env(:ourocode, :smoke_test, true)

    assert {:ok, result} =
             Ourocode.CLI.main(
               ["--project-dir", File.cwd!()],
               Ourocode.CLITest.TerminalBootstrapSpy
             )

    assert result.mode == :smoke_test
    assert result.interactive_ui_started? == false
    assert result.event_loop_started? == false
    refute_receive {:terminal_bootstrap, _context}, 50
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup accepts a natural-language task submission without command syntax" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main(
               ["Investigate", "MCP", "stream", "loss"],
               Ourocode.CLITest.DashboardSpy
             )

    assert_receive {:dashboard_init, ^context}

    assert %Ourocode.TaskRequest{
             source: :cli,
             task_input: "Investigate MCP stream loss",
             routing_decision: %{
               kind: :mcp_flow,
               execution_route: :mcp_flow,
               requires_command_syntax?: false
             }
           } = context.initial_task_request
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup applies configured parallel child and repeat count overrides" do
    original_parallel_child_count = Application.get_env(:ourocode, :parallel_child_count)
    original_repeat_count = Application.get_env(:ourocode, :repeat_count)

    on_exit(fn ->
      restore_env(:parallel_child_count, original_parallel_child_count)
      restore_env(:repeat_count, original_repeat_count)
    end)

    Application.put_env(:ourocode, :cli_test_pid, self())
    Application.put_env(:ourocode, :parallel_child_count, 8)
    Application.put_env(:ourocode, :repeat_count, 4)

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main([], Ourocode.CLITest.DashboardSpy)

    assert_receive {:dashboard_init, ^context}

    assert context.config == %{
             parallel_child_count: 8,
             repeat_count: 4,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 64,
             stale_cleanup_timeout_ms: 30_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 10_000,
             pane_state_retention_ms: 300_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 64,
               stale_cleanup_timeout_ms: 30_000,
               stream_subscription_cleanup_timeout_ms: 10_000,
               pane_state_retention_ms: 300_000
             }
           }
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "startup applies CLI pane retention and cleanup policy overrides" do
    Application.put_env(:ourocode, :cli_test_pid, self())

    args = [
      "--cleanup-policy.allowed-memory-growth-mb=192",
      "--cleanup-policy.stale-cleanup-timeout-ms=55000",
      "--cleanup-policy.stream-subscription-cleanup-timeout-ms=15000",
      "--cleanup-policy.pane-state-retention-ms=700000"
    ]

    assert {:ok, %{context: context}} =
             Ourocode.CLI.main(args, Ourocode.CLITest.DashboardSpy)

    assert_receive {:dashboard_init, ^context}

    assert context.config == %{
             parallel_child_count: 3,
             repeat_count: 1,
             stream_mailbox_capacity: 1_000,
             stream_mailbox_overflow_path: :drop,
             stream_mailbox_backpressure_threshold: 800,
             stream_mailbox_backpressure_behavior: :notify,
             stream_mailbox_backpressure_delay_ms: 10,
             allowed_memory_growth_mb: 192,
             stale_cleanup_timeout_ms: 55_000,
             operation_timeout_ms: 120_000,
             stream_subscription_cleanup_timeout_ms: 15_000,
             pane_state_retention_ms: 700_000,
             cleanup_policy: %{
               allowed_memory_growth_mb: 192,
               stale_cleanup_timeout_ms: 55_000,
               stream_subscription_cleanup_timeout_ms: 15_000,
               pane_state_retention_ms: 700_000
             }
           }
  after
    Application.delete_env(:ourocode, :cli_test_pid)
  end

  test "launch renders once and keeps the terminal event loop alive until explicit exit" do
    lines = start_lines(["Investigate streaming panes\n", "/exit\n"])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: next_line(lines)
                 )

        assert result.status == :healthy
        assert result.event_loop.status == :exit_signal_received
        assert result.event_loop.iterations == 2

        assert Enum.map(result.event_loop.submitted_tasks, & &1.task_input) == [
                 "Investigate streaming panes"
               ]
      end)

    assert output =~ "ourocode terminal"
    assert output =~ "+-- Task"
    assert output =~ "queued task"
    assert output =~ "exiting ourocode"
  end

  test "launch consumes piped stdin to EOF and exits cleanly without interactive input" do
    lines =
      start_lines([
        "Inspect stdin prompt flow\n",
        "Steer child pane from stdin\n"
      ])

    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: next_line(lines)
                 )

        assert result.status == :healthy
        assert result.event_loop.status == :input_eof
        assert result.event_loop.exit_signal == nil
        assert result.event_loop.iterations == 2

        assert Enum.map(result.event_loop.submitted_tasks, & &1.task_input) == [
                 "Inspect stdin prompt flow",
                 "Steer child pane from stdin"
               ]
      end)

    assert output =~ "ourocode terminal"
    assert output =~ "queued task"
    refute output =~ "exiting ourocode"
  end

  test "launch smoke test prints smoke summary and does not enter prompt loop" do
    output =
      capture_io(fn ->
        assert {:ok, result} =
                 Ourocode.CLI.launch(
                   ["--smoke-test", "--project-dir", File.cwd!()],
                   Ourocode.CLITest.InteractiveTerminalSpy,
                   read_line: fn _prompt -> flunk("smoke launch must not read terminal input") end
                 )

        assert result.mode == :smoke_test
        refute Map.has_key?(result, :event_loop)
      end)

    assert output =~ "ourocode smoke test: ok"
    assert output =~ "mode: smoke_test"
    assert output =~ "interactive_ui_started?: false"
    refute output =~ "ourocode terminal"
    refute output =~ "ourocode> "
  end

  defp restore_env(key, nil), do: Application.delete_env(:ourocode, key)
  defp restore_env(key, value), do: Application.put_env(:ourocode, key, value)

  defp start_lines(lines) do
    {:ok, pid} = Agent.start_link(fn -> lines end)
    pid
  end

  defp next_line(lines) do
    fn _prompt ->
      Agent.get_and_update(lines, fn
        [] -> {nil, []}
        [line | rest] -> {line, rest}
      end)
    end
  end

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp tmp_project_dir!(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{unique_id()}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    Process.put({__MODULE__, :tmp_project_dir}, dir)
    dir
  end

  defp cleanup_tmp_project_dir do
    case Process.get({__MODULE__, :tmp_project_dir}) do
      nil -> :ok
      dir -> File.rm_rf!(dir)
    end
  end

  defp plugin_config_json do
    """
    {
      "plugins": [
        {
          "identity": {
            "id": "ouroboros-plugin",
            "version": "1.0.0"
          },
          "path": "plugins/ouroboros",
          "entrypoint": {"type": "manifest", "path": "capabilities.json"},
          "enabled": true,
          "source": "official",
          "permissions": {
            "filesystem": [],
            "network": [],
            "process": []
          },
          "trust_policy": {
            "tier": "official",
            "requires_explicit_approval": false
          },
          "config": {
            "commands": true,
            "skills": true
          }
        }
      ]
    }
    """
  end
end
