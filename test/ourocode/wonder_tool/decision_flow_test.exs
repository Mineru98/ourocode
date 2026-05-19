defmodule Ourocode.WonderTool.DecisionFlowTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.WonderToolPromptRenderer
  alias Ourocode.Journal
  alias Ourocode.WonderTool.DecisionFlow

  test "prepares wonderTool decisions with the shared multiple-choice renderer" do
    assert {:ok, prepared} = DecisionFlow.prepare(request_fixture())

    assert prepared.request.tool == :wonder_tool
    assert prepared.rendered_prompt == WonderToolPromptRenderer.render(prepared.request)

    assert prepared.lines == [
             "[decision] Route: Which runtime should handle this task?",
             "  1. Ouroboros (Recommended) - Route through Ouroboros workflow execution.",
             "  2. OpenCode - Open a read-only OpenCode child session."
           ]

    assert [
             %{
               index: 1,
               marker: "1.",
               label: "Ouroboros (Recommended)",
               recommended?: true
             },
             %{index: 2, marker: "2.", label: "OpenCode", recommended?: false}
           ] =
             prepared.rendered_prompt.questions
             |> hd()
             |> Map.fetch!(:options)
  end

  test "captures one rendered option and persists the wonder decision to the journal" do
    path = journal_path("wonder-flow")

    try do
      assert {:ok,
              %{
                rendered_prompt: rendered_prompt,
                decision: %{
                  type: :wonder_decision,
                  request_id: "decision-flow-1",
                  child_id: "child-flow-1",
                  parent_call_id: "parent-flow-1",
                  external_ids: %{"session_id" => "session-flow-1"},
                  question_id: "route_choice",
                  question_kind: :decision,
                  selected_index: 2,
                  selected_label: "OpenCode",
                  selected_description: "Open a read-only OpenCode child session.",
                  selected_at_ms: 1_700
                },
                journaled?: true
              }} =
               DecisionFlow.run(
                 request_fixture(),
                 %{"questionId" => "route_choice", "selectedOption" => "2"},
                 journal_path: path,
                 event_seq: 7,
                 selected_at_ms: 1_700
               )

      assert rendered_prompt.title == "wonderTool"
      assert rendered_prompt.question_count == 1

      assert {:ok,
              [
                %{
                  event_seq: 7,
                  type: :wonder_decision,
                  question_id: "route_choice",
                  selected_index: 2,
                  selected_label: "OpenCode"
                }
              ]} = Journal.read_ordered(path)
    after
      File.rm(path)
    end
  end

  test "runs permission flow through the shared renderer and single-selection capture" do
    path = journal_path("wonder-permission-flow")

    try do
      assert {:ok,
              %{
                request: %{questions: [%{kind: :permission}]},
                rendered_prompt: rendered_prompt,
                decision: %{
                  type: :wonder_decision,
                  request_id: "permission-flow-1",
                  child_id: "child-permission-1",
                  parent_call_id: "parent-permission-1",
                  external_ids: %{"execution_id" => "exec-permission-1"},
                  question_id: "allow_cleanup_scan",
                  question_kind: :permission,
                  selected_index: 1,
                  selected_label: "Allow (Recommended)",
                  selected_description: "Inspect read-only process metadata for cleanup.",
                  selected_at_ms: 2_600
                },
                journaled?: true
              }} =
               DecisionFlow.run(
                 permission_request_fixture(),
                 %{
                   "questionId" => "allow_cleanup_scan",
                   "selectedOption" => "Allow (Recommended)"
                 },
                 journal_path: path,
                 event_seq: 11,
                 selected_at_ms: 2_600
               )

      assert rendered_prompt == WonderToolPromptRenderer.render(permission_request_fixture())

      assert rendered_prompt.lines == [
               "[permission] Permission: Allow ourocode to inspect process metadata for cleanup?",
               "  1. Allow (Recommended) - Inspect read-only process metadata for cleanup.",
               "  2. Deny - Continue without process metadata."
             ]

      assert {:ok,
              [
                %{
                  event_seq: 11,
                  type: :wonder_decision,
                  question_id: "allow_cleanup_scan",
                  question_kind: :permission,
                  selected_index: 1,
                  selected_label: "Allow (Recommended)"
                }
              ]} = Journal.read_ordered(path)
    after
      File.rm(path)
    end
  end

  test "runs clarification flow through the shared renderer and single-selection capture" do
    path = journal_path("wonder-clarification-flow")

    try do
      assert {:ok,
              %{
                request: %{questions: [%{kind: :clarification}]},
                rendered_prompt: rendered_prompt,
                decision: %{
                  type: :wonder_decision,
                  request_id: "clarify-flow-1",
                  child_id: "child-clarify-1",
                  parent_call_id: "parent-clarify-1",
                  external_ids: %{"thread_id" => "thread-clarify-1"},
                  question_id: "target_scope",
                  question_kind: :clarification,
                  selected_index: 3,
                  selected_label: "Codex",
                  selected_description: "Inspect native session and thread IDs first.",
                  selected_at_ms: 3_900
                },
                journaled?: true
              }} =
               DecisionFlow.run(
                 clarification_request_fixture(),
                 %{"questionId" => "target_scope", "selectedOption" => "Codex"},
                 journal_path: path,
                 event_seq: 13,
                 selected_at_ms: 3_900
               )

      assert rendered_prompt == WonderToolPromptRenderer.render(clarification_request_fixture())

      assert rendered_prompt.lines == [
               "[clarification] Clarify: Which source should be inspected first?",
               "  1. Ouroboros (Recommended) - Inspect sessions and jobs first.",
               "  2. OpenCode - Inspect childID pane mappings first.",
               "  3. Codex - Inspect native session and thread IDs first."
             ]

      assert {:ok,
              [
                %{
                  event_seq: 13,
                  type: :wonder_decision,
                  question_id: "target_scope",
                  question_kind: :clarification,
                  selected_index: 3,
                  selected_label: "Codex"
                }
              ]} = Journal.read_ordered(path)
    after
      File.rm(path)
    end
  end

  test "rejects multiple selected options before journal append" do
    path = journal_path("wonder-flow-reject")

    try do
      assert {:error, {:exactly_one_selection_required, 2}} =
               DecisionFlow.run(
                 request_fixture(),
                 %{"questionId" => "route_choice", "selectedOptions" => [1, 2]},
                 journal_path: path,
                 event_seq: 1
               )

      assert File.read(path) == {:error, :enoent}
    after
      File.rm(path)
    end
  end

  test "requires an event sequence when a flow is journaled" do
    assert {:error, :event_seq_required_for_journaled_wonder_decision} =
             DecisionFlow.run(
               request_fixture(),
               %{"questionId" => "route_choice", "selectedOption" => 1},
               journal_path: journal_path("wonder-flow-missing-seq")
             )
  end

  defp request_fixture do
    %{
      "tool" => "wonderTool",
      "arguments" => %{
        "requestId" => "decision-flow-1",
        "childID" => "child-flow-1",
        "parentCallId" => "parent-flow-1",
        "externalIds" => %{"session_id" => "session-flow-1"},
        "interaction_kind" => "decision",
        "questions" => [
          %{
            "id" => "route_choice",
            "header" => "Route",
            "question" => "Which runtime should handle this task?",
            "options" => [
              %{
                "label" => "Ouroboros (Recommended)",
                "description" => "Route through Ouroboros workflow execution."
              },
              %{
                "label" => "OpenCode",
                "description" => "Open a read-only OpenCode child session."
              }
            ]
          }
        ]
      }
    }
  end

  defp permission_request_fixture do
    %{
      "name" => "request_user_input",
      "arguments" => %{
        "requestId" => "permission-flow-1",
        "childID" => "child-permission-1",
        "parentCallId" => "parent-permission-1",
        "externalIds" => %{"execution_id" => "exec-permission-1"},
        "interaction_kind" => "permission",
        "questions" => [
          %{
            "id" => "allow_cleanup_scan",
            "header" => "Permission",
            "question" => "Allow ourocode to inspect process metadata for cleanup?",
            "options" => [
              %{
                "label" => "Allow (Recommended)",
                "description" => "Inspect read-only process metadata for cleanup."
              },
              %{
                "label" => "Deny",
                "description" => "Continue without process metadata."
              }
            ]
          }
        ]
      }
    }
  end

  defp clarification_request_fixture do
    %{
      "jsonrpc" => "2.0",
      "id" => "call-clarify-flow-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "request_user_input",
        "arguments" => %{
          "requestId" => "clarify-flow-1",
          "childId" => "child-clarify-1",
          "parent_call_id" => "parent-clarify-1",
          "externalIds" => %{"thread_id" => "thread-clarify-1"},
          "request_kind" => "clarification",
          "questions" => [
            %{
              "id" => "target_scope",
              "header" => "Clarify",
              "question" => "Which source should be inspected first?",
              "options" => [
                %{
                  "label" => "Ouroboros (Recommended)",
                  "description" => "Inspect sessions and jobs first."
                },
                %{
                  "label" => "OpenCode",
                  "description" => "Inspect childID pane mappings first."
                },
                %{
                  "label" => "Codex",
                  "description" => "Inspect native session and thread IDs first."
                }
              ]
            }
          ]
        }
      }
    }
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
