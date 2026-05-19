defmodule Ourocode.WonderTool.InteractionDetectorTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.InteractionDetector

  test "detects request_user_input MCP calls that require Socratic checkpoint handling" do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => "tool-call-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "request_user_input",
        "arguments" => %{
          "requestId" => "wonder-1",
          "childID" => "child-1",
          "parentCallId" => "parent-1",
          "externalIds" => %{"session_id" => "session-1"},
          "interaction_kind" => "socratic",
          "questions" => [
            %{
              "id" => "route_choice",
              "header" => "Route",
              "question" => "Which runtime should inspect this task first?",
              "options" => [
                %{
                  "label" => "Ouroboros (Recommended)",
                  "description" => "Start from workflow sessions and jobs."
                },
                %{
                  "label" => "OpenCode",
                  "description" => "Start from child pane mappings."
                }
              ]
            }
          ]
        }
      }
    }

    assert {:ok,
            %{
              applicable?: true,
              tool: :wonder_tool,
              type: :multiple_choice_checkpoint,
              requires_socratic_checkpoint?: true,
              request_id: "wonder-1",
              child_id: "child-1",
              parent_call_id: "parent-1",
              external_ids: %{"session_id" => "session-1"},
              checkpoint_kinds: [:socratic],
              question_count: 1,
              option_counts: [2],
              request: %{
                tool: :wonder_tool,
                type: :multiple_choice_decision,
                questions: [
                  %{
                    id: "route_choice",
                    kind: :socratic,
                    options: [
                      %{label: "Ouroboros (Recommended)", recommended?: true},
                      %{label: "OpenCode", recommended?: false}
                    ]
                  }
                ]
              }
            }} = InteractionDetector.detect(payload)

    assert InteractionDetector.applicable?(payload)
  end

  test "detects mixed permission and clarification multiple-choice checkpoints" do
    payload = %{
      "tool" => "wonderTool",
      "arguments" => %{
        "requestId" => "wonder-2",
        "questions" => [
          %{
            "id" => "allow_scan",
            "header" => "Permission",
            "kind" => "permission",
            "question" => "Allow read-only workspace inspection?",
            "options" => [
              %{"label" => "Allow (Recommended)", "description" => "Inspect local metadata."},
              %{"label" => "Deny", "description" => "Continue without inspection."}
            ]
          },
          %{
            "id" => "target_scope",
            "header" => "Clarify",
            "kind" => "clarification",
            "question" => "Which source should be inspected first?",
            "options" => [
              %{"label" => "Ouroboros", "description" => "Inspect workflow state."},
              %{"label" => "Codex", "description" => "Inspect native session IDs."},
              %{"label" => "OpenCode", "description" => "Inspect child IDs."}
            ]
          }
        ]
      }
    }

    assert {:ok,
            %{
              checkpoint_kinds: [:permission, :clarification],
              question_count: 2,
              option_counts: [2, 3],
              requires_socratic_checkpoint?: true
            }} = InteractionDetector.detect(payload)
  end

  test "detects legacy AskUserQuestion multiple-choice interactions" do
    payload = %{
      "tool" => "AskUserQuestion",
      "arguments" => %{
        "questions" => [
          %{
            "id" => "cleanup_policy",
            "header" => "Cleanup",
            "question" => "Which cleanup policy should apply?",
            "options" => [
              %{"label" => "Default (Recommended)", "description" => "Use configured timeouts."},
              %{"label" => "Keep panes", "description" => "Retain panes for inspection."}
            ]
          }
        ]
      }
    }

    assert {:ok,
            %{
              checkpoint_kinds: [:decision],
              request: %{questions: [%{id: "cleanup_policy"}]}
            }} = InteractionDetector.detect(payload)
  end

  test "ignores ordinary runtime events and non-multiple-choice interactions" do
    ordinary_tool_call = %{
      "method" => "tools/call",
      "params" => %{
        "name" => "synthetic.seq",
        "arguments" => %{"count" => 3}
      }
    }

    freeform_question = %{
      "name" => "request_user_input",
      "arguments" => %{
        "id" => "freeform_scope",
        "header" => "Clarify",
        "question" => "What should ourocode inspect?"
      }
    }

    plain_questions_payload = %{
      "questions" => [
        %{
          "id" => "route_choice",
          "header" => "Route",
          "question" => "Which runtime should handle this task?",
          "options" => [
            %{"label" => "Auto", "description" => "Use default routing."},
            %{"label" => "Manual", "description" => "Ask before routing."}
          ]
        }
      ]
    }

    assert :ignore = InteractionDetector.detect(ordinary_tool_call)
    assert :ignore = InteractionDetector.detect(freeform_question)
    assert :ignore = InteractionDetector.detect(plain_questions_payload)
    refute InteractionDetector.applicable?(ordinary_tool_call)
    refute InteractionDetector.applicable?(nil)
  end
end
