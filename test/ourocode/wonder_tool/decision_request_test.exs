defmodule Ourocode.WonderTool.DecisionRequestTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.DecisionRequest

  test "parses AskUserQuestion-style multiple-choice decision requests" do
    request = %{
      "tool" => "AskUserQuestion",
      "arguments" => %{
        "requestId" => "decision-1",
        "childID" => "child-1",
        "parentCallId" => "parent-1",
        "externalIds" => %{"session_id" => "session-1"},
        "questions" => [
          %{
            "header" => "Permission",
            "id" => "allow_scan",
            "kind" => "permission",
            "question" => "Allow the Rust scanner helper to inspect this workspace?",
            "options" => [
              %{
                "label" => "Allow (Recommended)",
                "description" => "Runs a read-only scan and continues the session."
              },
              %{
                "label" => "Deny",
                "description" => "Skips the scan and keeps the current context."
              }
            ]
          }
        ]
      }
    }

    assert {:ok,
            %{
              tool: :wonder_tool,
              type: :multiple_choice_decision,
              request_id: "decision-1",
              child_id: "child-1",
              parent_call_id: "parent-1",
              external_ids: %{"session_id" => "session-1"},
              questions: [
                %{
                  id: "allow_scan",
                  header: "Permission",
                  kind: :permission,
                  question: "Allow the Rust scanner helper to inspect this workspace?",
                  options: [
                    %{
                      label: "Allow (Recommended)",
                      description: "Runs a read-only scan and continues the session.",
                      recommended?: true
                    },
                    %{
                      label: "Deny",
                      description: "Skips the scan and keeps the current context.",
                      recommended?: false
                    }
                  ]
                }
              ],
              raw_request: ^request
            }} = DecisionRequest.parse(request)
  end

  test "parses optional multi-select question flag" do
    request = %{
      "tool" => "wonderTool",
      "arguments" => %{
        "questions" => [
          %{
            "header" => "Axes",
            "id" => "growth_axes",
            "question" => "Which growth axes apply?",
            "multiSelect" => true,
            "options" => [
              %{"label" => "Users", "description" => "Grow adoption."},
              %{"label" => "Business", "description" => "Create a sustainable model."}
            ]
          }
        ]
      }
    }

    assert {:ok, %{questions: [%{multi_select?: true}]}} = DecisionRequest.parse(request)
  end

  test "parses Other free-text and terminal preview placeholders on options" do
    request = %{
      "tool" => "wonderTool",
      "arguments" => %{
        "questions" => [
          %{
            "header" => "Preview",
            "id" => "asset_choice",
            "question" => "Which asset should be used?",
            "options" => [
              %{
                "label" => "Image",
                "description" => "Use the uploaded image.",
                "previewPlaceholder" => "[Image #1]",
                "preview" => "uploaded screenshot"
              },
              %{
                "label" => "Other",
                "description" => "Type a different asset.",
                "allowFreeText" => true
              }
            ]
          }
        ]
      }
    }

    assert {:ok, %{questions: [%{options: [image, other]}]}} = DecisionRequest.parse(request)
    assert image.preview == "uploaded screenshot"
    assert image.preview_placeholder == "[Image #1]"
    assert other.other? == true
  end

  test "parses request_user_input permission multiple-choice interaction requests" do
    request = %{
      "name" => "request_user_input",
      "arguments" => %{
        "request_id" => "permission-1",
        "interaction_kind" => "permission",
        "questions" => [
          %{
            "header" => "Permission",
            "id" => "allow_process_scan",
            "question" => "Allow ourocode to inspect local process metadata for cleanup?",
            "options" => [
              %{
                "label" => "Allow (Recommended)",
                "description" => "Records process IDs and cleanup cursors in the local journal."
              },
              %{
                "label" => "Deny",
                "description" => "Skips process metadata collection for this session."
              }
            ]
          }
        ]
      }
    }

    assert {:ok,
            %{
              request_id: "permission-1",
              questions: [
                %{
                  id: "allow_process_scan",
                  header: "Permission",
                  kind: :permission,
                  options: [
                    %{label: "Allow (Recommended)", recommended?: true},
                    %{label: "Deny", recommended?: false}
                  ]
                }
              ]
            }} = DecisionRequest.parse(request)
  end

  test "parses clarification multiple-choice interaction requests from MCP tools/call envelopes" do
    request = %{
      "jsonrpc" => "2.0",
      "id" => "call-1",
      "method" => "tools/call",
      "params" => %{
        "name" => "request_user_input",
        "arguments" => %{
          "requestId" => "clarify-1",
          "childId" => "child-clarify-1",
          "parent_call_id" => "parent-clarify-1",
          "request_kind" => "clarification",
          "questions" => [
            %{
              "header" => "Clarify",
              "id" => "target_scope",
              "question" => "Which runtime should this task inspect first?",
              "options" => [
                %{
                  "label" => "Ouroboros (Recommended)",
                  "description" => "Inspect Ouroboros sessions and jobs before other runtimes."
                },
                %{
                  "label" => "OpenCode",
                  "description" => "Start from OpenCode child sessions and pane mappings."
                },
                %{
                  "label" => "Codex",
                  "description" => "Start from Codex native session and thread identifiers."
                }
              ]
            }
          ]
        }
      }
    }

    assert {:ok,
            %{
              request_id: "clarify-1",
              child_id: "child-clarify-1",
              parent_call_id: "parent-clarify-1",
              questions: [
                %{
                  id: "target_scope",
                  header: "Clarify",
                  kind: :clarification,
                  question: "Which runtime should this task inspect first?",
                  options: [
                    %{label: "Ouroboros (Recommended)", recommended?: true},
                    %{label: "OpenCode", recommended?: false},
                    %{label: "Codex", recommended?: false}
                  ]
                }
              ],
              raw_request: ^request
            }} = DecisionRequest.parse(request)
  end

  test "allows per-question clarification kind to override a generic interaction kind" do
    request = %{
      tool_name: "wonderTool",
      input: %{
        interactionKind: "decision",
        questions: [
          %{
            id: "missing_fact",
            header: "Clarify",
            kind: "clarification",
            question: "Which missing fact should ourocode ask for?",
            options: [
              %{
                label: "Runtime",
                description: "Ask which runtime should receive the task."
              },
              %{
                label: "Transport (Recommended)",
                description: "Ask whether stdio, streamable HTTP, or SSE should be used."
              }
            ]
          }
        ]
      }
    }

    assert {:ok,
            %{
              questions: [
                %{
                  kind: :clarification,
                  options: [
                    %{label: "Runtime", recommended?: false},
                    %{label: "Transport (Recommended)", recommended?: true}
                  ]
                }
              ]
            }} = DecisionRequest.parse(request)
  end

  test "infers permission kind from compact permission header" do
    request = %{
      tool: "wonder_tool",
      questions: [
        %{
          id: "allow_workspace_read",
          header: "Permission",
          question: "Allow read-only workspace inspection?",
          options: [
            %{label: "Allow (Recommended)", description: "Inspect files under the workspace."},
            %{label: "Deny", description: "Continue without workspace inspection."}
          ]
        }
      ]
    }

    assert {:ok, %{questions: [%{kind: :permission}]}} = DecisionRequest.parse(request)
  end

  test "parses wonderTool single-question shorthand with choices" do
    request = %{
      tool: "wonderTool",
      id: "cleanup_policy",
      header: "Cleanup",
      prompt: "Which cleanup policy should apply?",
      choices: [
        "Default (Recommended)",
        "Aggressive",
        "Keep panes"
      ]
    }

    assert {:ok, %{questions: [question]}} = DecisionRequest.parse(request)
    assert question.id == "cleanup_policy"
    assert question.question == "Which cleanup policy should apply?"

    assert Enum.map(question.options, & &1.label) == [
             "Default (Recommended)",
             "Aggressive",
             "Keep panes"
           ]

    assert Enum.map(question.options, & &1.description) == [
             "Default (Recommended)",
             "Aggressive",
             "Keep panes"
           ]

    assert DecisionRequest.decision_request?(request)
  end

  test "rejects unsupported tool names" do
    assert {:error, {:unsupported_tool, "OtherTool"}} =
             DecisionRequest.parse(%{
               tool: "OtherTool",
               questions: [
                 %{
                   id: "route_choice",
                   header: "Route",
                   question: "Pick a route",
                   options: [
                     %{label: "Auto", description: "Use the router"},
                     %{label: "Manual", description: "Pick manually"}
                   ]
                 }
               ]
             })
  end

  test "validates question identity and compact UI header" do
    assert {:error, {:invalid_question, 0, :id_must_be_snake_case}} =
             DecisionRequest.parse(%{
               questions: [
                 %{
                   id: "RouteChoice",
                   header: "Route",
                   question: "Pick a route",
                   options: [
                     %{label: "Auto", description: "Use the router"},
                     %{label: "Manual", description: "Pick manually"}
                   ]
                 }
               ]
             })

    assert {:error, {:invalid_question, 0, :header_too_long}} =
             DecisionRequest.parse(%{
               questions: [
                 %{
                   id: "route_choice",
                   header: "Very Long Header",
                   question: "Pick a route",
                   options: [
                     %{label: "Auto", description: "Use the router"},
                     %{label: "Manual", description: "Pick manually"}
                   ]
                 }
               ]
             })
  end

  test "limits a single interaction request to three questions" do
    question = %{
      id: "route_choice",
      header: "Route",
      question: "Pick a route",
      options: [
        %{label: "Auto", description: "Use the router"},
        %{label: "Manual", description: "Pick manually"}
      ]
    }

    assert {:error, :at_most_three_questions_allowed} =
             DecisionRequest.parse(%{
               questions: [
                 question,
                 %{question | id: "route_choice_two"},
                 %{question | id: "route_choice_three"},
                 %{question | id: "route_choice_four"}
               ]
             })
  end

  test "requires two to four multiple-choice options with labels and descriptions" do
    assert {:error, {:invalid_question, 0, :at_least_two_options_required}} =
             DecisionRequest.parse(%{
               questions: [
                 %{
                   id: "route_choice",
                   header: "Route",
                   question: "Pick a route",
                   options: [
                     %{label: "Auto", description: "Use the router"}
                   ]
                 }
               ]
             })

    five_options =
      Enum.map(1..5, fn n ->
        %{label: "Option #{n}", description: "Choose option #{n}"}
      end)

    assert {:error, {:invalid_question, 0, :at_most_four_options_allowed}} =
             DecisionRequest.parse(%{
               questions: [
                 %{
                   id: "route_choice",
                   header: "Route",
                   question: "Pick a route",
                   options: five_options
                 }
               ]
             })

    assert {:error, {:invalid_question, 0, {:invalid_option, 1, :description_required}}} =
             DecisionRequest.parse(%{
               questions: [
                 %{
                   id: "route_choice",
                   header: "Route",
                   question: "Pick a route",
                   options: [
                     %{label: "Auto", description: "Use the router"},
                     %{label: "Manual"}
                   ]
                 }
               ]
             })
  end

  test "rejects malformed multiple-choice option payloads consistently across interaction flows" do
    invalid_options = [
      "Allow (Recommended)",
      %{label: "Deny", description: "Keep the current session state."}
    ]

    cases = [
      {:socratic,
       %{
         tool: "wonderTool",
         kind: "socratic",
         questions: [
           question_fixture(%{
             id: "socratic_choice",
             header: "Decide",
             kind: "socratic",
             options: invalid_options
           })
         ]
       }},
      {:permission,
       %{
         name: "request_user_input",
         arguments: %{
           interaction_kind: "permission",
           questions: [
             question_fixture(%{
               id: "permission_choice",
               header: "Permission",
               options: invalid_options
             })
           ]
         }
       }},
      {:clarification,
       %{
         "jsonrpc" => "2.0",
         "id" => "call-clarify-options",
         "method" => "tools/call",
         "params" => %{
           "name" => "request_user_input",
           "arguments" => %{
             "request_kind" => "clarification",
             "questions" => [
               question_fixture(%{
                 id: "clarify_choice",
                 header: "Clarify",
                 kind: "clarification",
                 options: invalid_options
               })
             ]
           }
         }
       }},
      {:decision,
       %{
         tool_name: "wonderTool",
         input: %{
           interactionKind: "decision",
           questions: [
             question_fixture(%{
               id: "decision_choice",
               header: "Decide",
               options: invalid_options
             })
           ]
         }
       }}
    ]

    for {flow, request} <- cases do
      assert {:error, {:invalid_question, 0, {:invalid_option, 0, :option_must_be_map}}} =
               DecisionRequest.parse(request),
             "expected malformed options payload to be rejected for #{flow}"

      refute DecisionRequest.decision_request?(request)
    end
  end

  test "rejects non-list multiple-choice options payloads across wrapped flows" do
    malformed_options = %{
      "0" => %{label: "Allow", description: "Continue the session."},
      "1" => %{label: "Deny", description: "Stop the action."}
    }

    requests = [
      %{
        tool: "wonderTool",
        questions: [
          question_fixture(%{
            id: "direct_options",
            header: "Decide",
            options: malformed_options
          })
        ]
      },
      %{
        "method" => "tools/call",
        "params" => %{
          "name" => "request_user_input",
          "arguments" => %{
            "questions" => [
              question_fixture(%{
                id: "wrapped_options",
                header: "Clarify",
                options: malformed_options
              })
            ]
          }
        }
      }
    ]

    for request <- requests do
      assert {:error, {:invalid_question, 0, :options_must_be_list}} =
               DecisionRequest.parse(request)
    end
  end

  defp question_fixture(overrides) do
    Map.merge(
      %{
        id: "route_choice",
        header: "Route",
        question: "Which path should ourocode use?",
        options: [
          %{label: "Auto (Recommended)", description: "Let ourocode pick the next path."},
          %{label: "Manual", description: "Ask before choosing the next path."}
        ]
      },
      overrides
    )
  end
end
