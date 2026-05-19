defmodule Ourocode.WonderTool.SelectionHandlerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Journal
  alias Ourocode.WonderTool.SelectionHandler

  test "captures exactly one selected option as a wonder decision" do
    assert {:ok,
            %{
              type: :wonder_decision,
              request_id: "decision-1",
              child_id: "child-1",
              parent_call_id: "parent-1",
              external_ids: %{"session_id" => "session-1"},
              question_id: "route_choice",
              question_kind: :decision,
              selected_index: 2,
              selected_label: "OpenCode",
              selected_description: "Open a read-only OpenCode child session.",
              selected_option: %{
                label: "OpenCode",
                description: "Open a read-only OpenCode child session.",
                recommended?: false
              },
              selected_at_ms: 1_234
            }} =
             SelectionHandler.capture(
               request_fixture(),
               %{"questionId" => "route_choice", "selectedOptions" => ["2"]},
               selected_at_ms: 1_234
             )
  end

  test "captures a selected option by label" do
    assert {:ok,
            %{
              question_id: "route_choice",
              selected_index: 1,
              selected_label: "Ouroboros (Recommended)"
            }} =
             SelectionHandler.capture(
               request_fixture(),
               %{"question_id" => "route_choice", "selected_option" => "Ouroboros (Recommended)"}
             )
  end

  test "infers the question when the request contains one question" do
    assert {:ok,
            %{
              question_id: "route_choice",
              selected_index: 2,
              selected_label: "OpenCode"
            }} = SelectionHandler.capture(request_fixture(), 2)
  end

  test "rejects empty selections" do
    assert {:error, :selection_required} =
             SelectionHandler.capture(request_fixture(), %{
               "questionId" => "route_choice",
               "selectedOptions" => []
             })

    assert {:error, :selection_required} =
             SelectionHandler.capture(request_fixture(), %{
               "questionId" => "route_choice",
               "selectedOption" => " "
             })
  end

  test "rejects multiple selected options" do
    assert {:error, {:exactly_one_selection_required, 2}} =
             SelectionHandler.capture(request_fixture(), %{
               "questionId" => "route_choice",
               "selectedOptions" => [1, 2]
             })
  end

  test "captures multiple options when the question enables multi-select" do
    request =
      request_fixture(%{
        "questions" => [
          question_fixture(%{
            "id" => "growth_axes",
            "header" => "Growth",
            "question" => "Which growth axes should be pursued?",
            "multiSelect" => true,
            "options" => [
              %{"label" => "Users", "description" => "Grow developer adoption."},
              %{"label" => "Features", "description" => "Fill missing product capability."},
              %{"label" => "Business", "description" => "Build a sustainable model."}
            ]
          })
        ]
      })

    assert {:ok,
            %{
              multi_select?: true,
              selected_index: 1,
              selected_label: "Users, Business",
              selected_indices: [1, 3],
              selected_labels: ["Users", "Business"],
              selected_descriptions: [
                "Grow developer adoption.",
                "Build a sustainable model."
              ]
            }} =
             SelectionHandler.capture(request, %{
               "questionId" => "growth_axes",
               "selectedOptions" => [1, 3]
             })
  end

  test "captures Other free-text, annotations, and selected preview placeholders" do
    request =
      request_fixture(%{
        "questions" => [
          question_fixture(%{
            "id" => "asset_choice",
            "header" => "Preview",
            "question" => "Which asset should be used?",
            "options" => [
              %{
                "label" => "Image",
                "description" => "Use the uploaded image.",
                "previewPlaceholder" => "[Image #1]"
              },
              %{
                "label" => "Other",
                "description" => "Type a different asset.",
                "allowFreeText" => true
              }
            ]
          })
        ]
      })

    assert {:ok,
            %{
              question_id: "asset_choice",
              selected_label: "Image",
              selected_preview_placeholders: ["[Image #1]"],
              annotation: "Crop to the modal only"
            }} =
             SelectionHandler.capture(request, %{
               "questionId" => "asset_choice",
               "selectedOption" => "Image",
               "note" => "Crop to the modal only"
             })

    assert {:ok,
            %{
              question_id: "asset_choice",
              selected_label: "Other",
              free_text: "Use the latest screenshot instead"
            }} =
             SelectionHandler.capture(request, %{
               "questionId" => "asset_choice",
               "otherText" => "Use the latest screenshot instead"
             })
  end

  test "rejects selections that do not match an available option" do
    assert {:error, {:unknown_selected_option, 3}} =
             SelectionHandler.capture(request_fixture(), %{
               "questionId" => "route_choice",
               "selectedOption" => 3
             })
  end

  test "requires a question id when a request has multiple questions" do
    base_request = request_fixture()

    request = %{
      base_request
      | "arguments" => %{
          base_request["arguments"]
          | "questions" => [
              question_fixture(%{"id" => "route_choice"}),
              question_fixture(%{"id" => "cleanup_choice", "header" => "Cleanup"})
            ]
        }
    }

    assert {:error, :question_id_required} = SelectionHandler.capture(request, 1)

    assert {:ok, %{question_id: "cleanup_choice", selected_index: 1}} =
             SelectionHandler.capture(request, %{
               "questionId" => "cleanup_choice",
               "selectedOption" => 1
             })
  end

  test "captured wonder decisions round-trip through the local journal" do
    path = journal_path("wonder-selection")

    assert {:ok, decision} =
             SelectionHandler.capture(request_fixture(), %{
               "questionId" => "route_choice",
               "selectedOption" => 1
             })

    Journal.append!(path, Map.put(decision, :event_seq, 1))

    assert {:ok,
            [
              %{
                event_seq: 1,
                type: :wonder_decision,
                question_id: "route_choice",
                question_kind: :decision,
                selected_index: 1,
                selected_label: "Ouroboros (Recommended)"
              }
            ]} = Journal.read_ordered(path)
  end

  defp request_fixture(overrides \\ %{}) do
    %{
      "tool" => "wonderTool",
      "arguments" =>
        Map.merge(
          %{
            "requestId" => "decision-1",
            "childID" => "child-1",
            "parentCallId" => "parent-1",
            "externalIds" => %{"session_id" => "session-1"},
            "interaction_kind" => "decision",
            "questions" => [
              question_fixture(%{"id" => "route_choice"})
            ]
          },
          overrides
        )
    }
  end

  defp question_fixture(overrides) do
    Map.merge(
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
      },
      overrides
    )
  end

  defp journal_path(name) do
    path =
      Path.join(System.tmp_dir!(), "ourocode-#{name}-#{System.unique_integer([:positive])}.jsonl")

    File.rm(path)
    path
  end
end
