defmodule Ourocode.Runtime.WorkflowRelayTest do
  use ExUnit.Case, async: true

  alias Ourocode.MCP.ParentCallResult
  alias Ourocode.Dashboard.ChildSessionPanes
  alias Ourocode.Json
  alias Ourocode.Runtime.{Dispatcher, WorkflowRelay}

  test "captures background workflow handles from starter response metadata" do
    {:ok, agent} = Agent.start_link(fn -> %{workflow: %{}, child: ChildSessionPanes.new()} end)

    result = %ParentCallResult{
      parent_call_id: "parent-auto-1",
      runtime_source: "ouroboros",
      transport: :streamable_http,
      external_ids: %{"job_id" => "job-auto-1"},
      response: %{
        "result" => %{
          "meta" => %{
            "auto_session_id" => "auto-1",
            "session_id" => "session-1",
            "execution_id" => "exec-1",
            "lineage_id" => "lin-1"
          },
          "content" => [%{"type" => "text", "text" => "Auto started"}]
        }
      }
    }

    assert :ok = WorkflowRelay.capture_workflow_result(agent, result, File.cwd!())

    workflow = Agent.get(agent, & &1.workflow)

    assert workflow.latest_job_id == "job-auto-1"
    assert workflow.latest_auto_session_id == "auto-1"
    assert workflow.latest_workflow_session_id == "session-1"
    assert workflow.latest_execution_id == "exec-1"
    assert workflow.latest_lineage_id == "lin-1"

    rendered_child =
      agent
      |> Agent.get(& &1.child)
      |> ChildSessionPanes.render()

    assert rendered_child.focused == "child-session:job-auto-1"

    assert [
             %{
               id: "child-session:job-auto-1",
               child_id: "job-auto-1",
               parent_call_id: "parent-auto-1",
               external_ids: %{
                 "job_id" => "job-auto-1",
                 "auto_session_id" => "auto-1",
                 "session_id" => "session-1",
                 "execution_id" => "exec-1",
                 "lineage_id" => "lin-1"
               }
             }
           ] = rendered_child.working

    pane_model = %{panes: Map.new(rendered_child.working, &{&1.id, &1}), open: rendered_child.open}

    input_event = %{
      type: :prompt_input_submitted,
      task_request_id: "task-steer-auto-1",
      task_input: "continue the auto run with stricter acceptance criteria",
      focused_pane: "child-session:job-auto-1",
      steering_target: :child,
      steering_target_pane_id: "child-session:job-auto-1",
      steering_target_session_id: "job-auto-1",
      steering_target_kind: :child_session,
      steering_text: "continue the auto run with stricter acceptance criteria",
      steering_message: %{
        type: :pane_directed_steering_message,
        target_pane_id: "child-session:job-auto-1",
        target_session_id: "job-auto-1",
        target_kind: :child_session,
        content: "continue the auto run with stricter acceptance criteria"
      }
    }

    dispatcher = fn pane, serialized_message, context ->
      send(self(), {:steered_background_job, pane, serialized_message, context})
      {:ok, :delivered}
    end

    assert {:ok,
            %{
              pane: %{id: "child-session:job-auto-1", child_id: "job-auto-1"},
              serialized_message: serialized_message,
              decoded_message: decoded_message,
              delivery_result: :delivered
            }} =
             Dispatcher.dispatch_steering_message(input_event,
               pane_model: pane_model,
               child_pane_dispatcher: dispatcher
             )

    assert_receive {:steered_background_job, %{id: "child-session:job-auto-1"},
                    ^serialized_message, %{decoded_message: ^decoded_message}}

    assert {:ok, wire_message} = Json.decode(serialized_message)
    assert wire_message["type"] == "pane_directed_steering_message"
    assert wire_message["target_pane_id"] == "child-session:job-auto-1"
    assert wire_message["target_session_id"] == "job-auto-1"
    assert wire_message["child_id"] == "job-auto-1"
    assert wire_message["content"] == "continue the auto run with stricter acceptance criteria"
  end
end
