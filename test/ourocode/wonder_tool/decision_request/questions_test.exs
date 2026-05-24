defmodule Ourocode.WonderTool.DecisionRequest.QuestionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.DecisionRequest.Questions

  test "normalizes question fields, request kind, options, and multi-select flag" do
    questions = [
      %{
        "id" => "scope_choice",
        "header" => "Scope",
        "question" => "Which scope applies?",
        "multiSelect" => "true",
        "choices" => ["Small", "Large (Recommended)"]
      }
    ]

    assert {:ok, [question]} = Questions.normalize(questions, :clarification)

    assert question.id == "scope_choice"
    assert question.header == "Scope"
    assert question.kind == :clarification
    assert question.multi_select?

    assert [%{label: "Small"}, %{label: "Large (Recommended)", recommended?: true}] =
             question.options
  end

  test "infers permission kind from header when no kind is provided" do
    questions = [
      %{
        id: "allow_scan",
        header: "Permission",
        question: "Allow scan?",
        options: [
          %{label: "Allow", description: "Proceed."},
          %{label: "Deny", description: "Skip."}
        ]
      }
    ]

    assert {:ok, [%{kind: :permission}]} = Questions.normalize(questions, nil)
  end

  test "returns indexed question errors" do
    assert Questions.normalize([%{"id" => "Bad-Id"}], nil) ==
             {:error, {:invalid_question, 0, :id_must_be_snake_case}}
  end

  test "extracts request kind aliases" do
    assert Questions.request_kind(%{"interactionKind" => "permission"}) == :permission
    assert Questions.request_kind(%{request_kind: :socratic}) == :socratic
    assert Questions.request_kind(%{"request_kind" => "unknown"}) == nil
  end
end
