defmodule Ourocode.Dashboard.ApplicationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.Application

  test "initializer returns a healthy compact dashboard startup result" do
    project_dir = File.cwd!()
    context = %{project_dir: project_dir, cwd: project_dir}

    assert {:ok, result} = Application.init(context)

    assert result.status == :healthy
    assert result.healthy? == true
    assert result.runtime_source == "ourocode"
    assert result.context.project_dir == Path.expand(project_dir)
    assert result.context.cwd == project_dir
    assert result.context.config == %{
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

    assert result.config == %{
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
    assert result.prompt_placeholder == "Describe a task for a new session"
    assert result.panes.task_prompt == %{
             id: :task_prompt,
             kind: :natural_language_task_input,
             title: "Task",
             placeholder: "Describe a task for a new session",
             value: "",
             cursor_position: 0,
             focused?: true,
             editable?: true,
             representative_ux: :natural_language_task_input,
             submit_action: :start_session,
             layout: %{
               mode: :compact,
               region: :task_prompt,
               order: 1,
               rect: %{x: 0, y: 22, width: 72, height: 3}
             }
           }

    assert %{
             id: :working_sessions,
             title: "Working",
             empty?: true,
             rows: [],
             layout: working_layout
           } = result.panes.working

    assert result.panes.completed == %{
             id: :completed_sessions,
             title: "Completed",
             empty?: true,
             rows: [],
             layout: %{
               mode: :compact,
               region: :session_lists,
               order: 2,
               rect: %{x: 0, y: 11, width: 36, height: 10}
             }
           }

    assert working_layout == %{
             mode: :compact,
             region: :session_lists,
             order: 1,
             rect: %{x: 0, y: 0, width: 36, height: 10}
           }

    assert result.panes.layout.regions.session_lists.panes == [
             :working_sessions,
             :completed_sessions
           ]

    assert result.panes.focused == nil
    assert result.panes.open == []
    assert result.health.project_dir == :ok
    assert result.health.dashboard_state == :ok
    assert is_integer(result.health.checked_at_ms)
  end

  test "initializer reports an unhealthy result for a missing project directory" do
    missing_dir =
      Path.join(System.tmp_dir!(), "ourocode-missing-#{System.unique_integer([:positive])}")

    assert {:error, result} = Application.init(%{project_dir: missing_dir})

    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.reason == {:missing_project_dir, Path.expand(missing_dir)}
  end

  test "initializer reports an unhealthy result for invalid context" do
    assert {:error, result} = Application.init(%{})

    assert result.status == :unhealthy
    assert result.healthy? == false
    assert result.reason == :invalid_project_context
  end
end
