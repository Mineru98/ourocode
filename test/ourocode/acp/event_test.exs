defmodule Ourocode.ACP.EventTest do
  use ExUnit.Case, async: true

  alias Ourocode.ACP.Event

  test "normalizes MCP parent and child lifecycle into ACP events" do
    events =
      Event.from_runtime_event(%{
        type: :parent_call_event,
        parent_call_id: "parent-acp-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        event_seq: 7,
        occurred_at_ms: 777,
        notification: %{"params" => %{"childID" => "child-acp-1", "token" => "hello"}}
      })

    assert %{
             kind: :acp_event,
             type: :tool_call,
             parent_call_id: "parent-acp-1",
             status: :streaming
           } = Enum.find(events, &(&1.type == :tool_call))

    assert %{
             kind: :acp_event,
             type: :agent_session,
             parent_call_id: "parent-acp-1",
             child_id: "child-acp-1",
             status: :streaming
           } = Enum.find(events, &(&1.type == :agent_session))
  end

  test "normalizes MCP user interaction into ACP decision request" do
    [decision] =
      Event.from_runtime_event(%{
        type: :parent_call_event,
        parent_call_id: "parent-decision-1",
        runtime_source: "grok",
        transport: :stdio,
        event_seq: 3,
        notification: %{
          "method" => "tools/call",
          "params" => %{
            "name" => "request_user_input",
            "arguments" => %{
              "requestId" => "decision-1",
              "questions" => [
                %{
                  "id" => "scope",
                  "header" => "Scope",
                  "question" => "Pick scope",
                  "options" => [
                    %{"label" => "Narrow", "description" => "Small fix"},
                    %{"label" => "Broad", "description" => "Full pass"}
                  ]
                }
              ]
            }
          }
        }
      })
      |> Enum.filter(&(&1.type == :decision_request))

    assert %{
             decision_id: "decision-1",
             parent_call_id: "parent-decision-1",
             question_count: 1,
             option_counts: [2],
             status: :pending
           } = decision
  end

  test "normalizes bridged MCP permission notifications into ACP decisions" do
    [decision] =
      Event.from_runtime_event(%{
        type: :parent_call_event,
        parent_call_id: "parent-permission-acp-1",
        runtime_source: "grok",
        transport: :stdio,
        notification: %{
          "method" => "session/request_permission",
          "params" => %{
            "requestId" => "perm-acp-1",
            "childID" => "child-permission-acp-1",
            "description" => "Run `git diff`?"
          }
        }
      })
      |> Enum.filter(&(&1.type == :decision_request))

    assert %{
             decision_id: "perm-acp-1",
             parent_call_id: "parent-permission-acp-1",
             child_id: "child-permission-acp-1",
             checkpoint_kinds: [:permission],
             option_counts: [2]
           } = decision
  end

  test "keeps parent_call_result child sessions streaming until result says completed" do
    events =
      Event.from_runtime_event(%{
        type: :parent_call_result,
        parent_call_id: "parent-child-status-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        result: %{"childID" => "child-status-1", "status" => "running"}
      })

    assert %{status: :streaming} = Enum.find(events, &(&1.type == :agent_session))

    events =
      Event.from_runtime_event(%{
        type: :parent_call_result,
        parent_call_id: "parent-child-status-1",
        runtime_source: "ouroboros",
        transport: :streamable_http,
        result: %{"childID" => "child-status-1", "status" => "completed"}
      })

    assert %{status: :completed} = Enum.find(events, &(&1.type == :agent_session))
  end
end
