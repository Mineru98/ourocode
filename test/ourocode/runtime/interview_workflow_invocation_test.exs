defmodule Ourocode.Runtime.InterviewWorkflowInvocationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.Dispatcher
  alias Ourocode.Runtime.InterviewWorkflowInvocation
  alias Ourocode.TaskRequest

  test "builds the initial streamable HTTP MCP interview payload with preserved prompt text" do
    prompt = "ooo interview define ourocode MCP streamable UI requirements."
    task_request = parse_interview_prompt!(prompt)

    assert {:ok, payload} =
             InterviewWorkflowInvocation.build_initial_request_payload(task_request,
               request_id: "req-interview-1",
               cwd: "/workspace/ourocode"
             )

    assert payload == %{
             "jsonrpc" => "2.0",
             "id" => "req-interview-1",
             "method" => "tools/call",
             "params" => %{
               "name" => "ouroboros_interview",
               "arguments" => %{
                 "initial_context" => prompt,
                 "cwd" => "/workspace/ourocode"
               }
             }
           }
  end

  test "dispatch invocation receives the task request and passes the payload to the configured MCP invoker" do
    parent = self()
    prompt = "ooo interview define streamable HTTP child pane requirements."
    task_request = parse_interview_prompt!(prompt)

    invoker = fn payload, transport_options ->
      send(parent, {:mcp_invoked, payload, transport_options})
      {:ok, %{parent_call_id: "parent-interview-1"}}
    end

    assert {:ok,
            %{
              type: :interview_workflow_invocation,
              status: :invoked,
              task_request_id: "interview-task",
              prompt_text: ^prompt,
              transport: :streamable_http,
              mcp_tool: "ouroboros_interview",
              request_payload: %{
                "method" => "tools/call",
                "params" => %{
                  "name" => "ouroboros_interview",
                  "arguments" => %{"initial_context" => ^prompt}
                }
              },
              result: %{parent_call_id: "parent-interview-1"}
            }} =
             Dispatcher.dispatch(task_request,
               adapters: %{{:ouroboros_workflow, :interview} => InterviewWorkflowInvocation},
               context: %{
                 request_id: "req-interview-dispatch",
                 streamable_http_url: "http://localhost:4000/mcp",
                 journal_path: "/tmp/ourocode-interview.jsonl",
                 mcp_invoker: invoker
               }
             )

    assert_receive {:mcp_invoked, payload, transport_options}
    assert payload["id"] == "req-interview-dispatch"
    assert payload["params"]["arguments"]["initial_context"] == prompt

    assert transport_options == %{
             transport: :streamable_http,
             url: "http://localhost:4000/mcp",
             journal_path: "/tmp/ourocode-interview.jsonl"
           }
  end

  test "builds a followup payload that returns one recorded answer to a live session" do
    assert {:ok, payload} =
             InterviewWorkflowInvocation.build_followup_request_payload(
               "iv-sess-42",
               "[from-code] Elixir 1.15, escript CLI (mix.exs)",
               request_id: "req-followup-1"
             )

    assert payload == %{
             "jsonrpc" => "2.0",
             "id" => "req-followup-1",
             "method" => "tools/call",
             "params" => %{
               "name" => "ouroboros_interview",
               "arguments" => %{
                 "session_id" => "iv-sess-42",
                 "answer" => "[from-code] Elixir 1.15, escript CLI (mix.exs)"
               }
             }
           }
  end

  test "followup payload defaults the request id from the session and forwards last_question" do
    assert {:ok, payload} =
             InterviewWorkflowInvocation.build_followup_request_payload(
               "iv-sess-7",
               "[from-user][refined] Decision: ...",
               last_question: "What scope is missing from the one-sentence goal?"
             )

    assert payload["id"] == "interview-followup-iv-sess-7"

    assert payload["params"]["arguments"] == %{
             "session_id" => "iv-sess-7",
             "answer" => "[from-user][refined] Decision: ...",
             "last_question" => "What scope is missing from the one-sentence goal?"
           }
  end

  test "followup payload rejects an empty session id" do
    assert {:error, :invalid_followup_request} =
             InterviewWorkflowInvocation.build_followup_request_payload("", "answer")
  end

  test "rejects non-interview task requests" do
    assert {:ok, task_request} =
             TaskRequest.parse("Inspect runtime pane state", id: "runtime-task")

    assert {:error, {:unsupported_interview_route, %{execution_route: :runtime}}} =
             InterviewWorkflowInvocation.execute(task_request, %{})
  end

  defp parse_interview_prompt!(prompt) do
    assert {:ok, %TaskRequest{} = task_request} =
             TaskRequest.parse(prompt, id: "interview-task", submitted_at_ms: 123)

    assert %{
             kind: :ouroboros_workflow,
             execution_route: :ouroboros_workflow,
             runtime_source: :ouroboros,
             requires_command_syntax?: false,
             advanced_shortcut?: true,
             reason: :explicit_ouroboros_shortcut,
             adapter_route: :interview
           } = task_request.routing_decision

    assert task_request.routing_decision.transport in [:auto, :streamable_http]

    task_request
  end
end
