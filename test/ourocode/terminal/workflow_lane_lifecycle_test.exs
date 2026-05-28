defmodule Ourocode.Terminal.WorkflowLaneLifecycleTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{WorkflowLaneLifecycle, WorkspaceModel, WorkspaceText}

  test "applies runtime stream cancel and failure events to a submitted workflow lane" do
    pane_model = %{
      panes: %{
        "workflow:task-1" => %{
          id: "workflow:task-1",
          kind: :workflow_session,
          session_id: "task-1",
          status: "queued",
          task: "ooo pm verify lifecycle",
          last_line: "waiting for first prompt"
        }
      },
      open: ["workflow:task-1"]
    }

    streaming =
      WorkflowLaneLifecycle.apply_events(pane_model, "workflow:task-1", [
        %{
          type: :stream_started,
          line: "stream: started",
          parent_call_id: "parent-1",
          focused?: true
        },
        %{type: :stream_event, line: "stream: token", focused?: true}
      ])

    assert get_in(streaming, [:panes, "workflow:task-1", :status]) == "running"
    assert get_in(streaming, [:panes, "workflow:task-1", :event_count]) == 2
    assert get_in(streaming, [:panes, "workflow:task-1", :pane_state, :focused?]) == true

    cancelled =
      WorkflowLaneLifecycle.apply_event(streaming, "workflow:task-1", %{
        type: :cancelled,
        line: "cancel acknowledged"
      })

    assert get_in(cancelled, [:panes, "workflow:task-1", :status]) == "cancelled"

    paused =
      WorkflowLaneLifecycle.apply_event(streaming, "workflow:task-1", %{
        type: :paused,
        line: "paused by user"
      })

    assert get_in(paused, [:panes, "workflow:task-1", :status]) == "paused"

    resumed =
      WorkflowLaneLifecycle.apply_event(paused, "workflow:task-1", %{
        type: :resumed,
        line: "resumed by user"
      })

    assert get_in(resumed, [:panes, "workflow:task-1", :status]) == "running"

    failed =
      WorkflowLaneLifecycle.apply_event(streaming, "workflow:task-1", %{
        type: :failed,
        line: "model exited with error",
        exit_code: 1
      })

    text =
      "/agents"
      |> WorkspaceModel.build(%{startup_result: %{}, pane_model: failed}, %{})
      |> WorkspaceText.render()

    assert text =~ "failed · needs attention"
    assert text =~ "Model exited with error"
    refute text =~ "controls: inspect error, retry, cancel"
    refute text =~ "focused in workspace"
    refute text =~ "exit 1"
    refute text =~ "updates received"
  end

  test "runtime stream events can update visible auto workflow phases" do
    pane_model = %{
      panes: %{
        "workflow:auto-1" => %{
          id: "workflow:auto-1",
          kind: :workflow_session,
          session_id: "auto-1",
          status: "queued",
          task: "ooo auto improve startup",
          last_line: "interview -> plan -> approval -> verify"
        }
      },
      open: ["workflow:auto-1"]
    }

    progressed =
      WorkflowLaneLifecycle.apply_event(pane_model, "workflow:auto-1", %{
        type: :stream_event,
        step: "approval",
        current: "approval required before file changes",
        progress: ["interview complete", "seed plan drafted", "waiting for approval"],
        controls: ["approve", "edit plan", "cancel"],
        line: "approval checkpoint ready",
        focused?: true
      })

    text =
      "/agents"
      |> WorkspaceModel.build(%{startup_result: %{}, pane_model: progressed}, %{})
      |> WorkspaceText.render()

    assert text =~ "Auto run - running · live"
    assert text =~ "stage updating"
    assert text =~ "Approval required before file changes"
    assert text =~ "progress interview complete, seed plan drafted, waiting for approval"
    refute text =~ "controls: approve, edit plan, cancel"
  end
end
