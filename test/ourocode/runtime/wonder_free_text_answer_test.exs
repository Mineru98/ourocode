defmodule Ourocode.Runtime.WonderFreeTextAnswerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.WonderFreeTextAnswer

  test "captures free text for a targeted question" do
    request = request()

    assert {:ok, decision} =
             WonderFreeTextAnswer.capture(request, %{
               "questionId" => "scope",
               "freeText" => "  whole module with migration tests  "
             })

    assert decision.question_id == "scope"
    assert decision.selected_label == "whole module with migration tests"
    assert decision.free_text == "whole module with migration tests"
    assert decision.selected_option.free_text? == true
    assert decision.request_id == "ask-1"
    assert decision.child_id == "child-1"
    assert decision.parent_call_id == "parent-1"
  end

  test "supports alternate free text keys and falls back to first question" do
    assert WonderFreeTextAnswer.selection_text(%{other_text: " custom answer "}) ==
             "custom answer"

    assert {:ok, decision} =
             WonderFreeTextAnswer.capture(request(), %{
               :question_id => "missing",
               :otherText => "fallback answer"
             })

    assert decision.question_id == "transport"
    assert decision.selected_label == "fallback answer"
  end

  test "rejects empty or missing free text" do
    assert WonderFreeTextAnswer.capture(request(), %{"freeText" => " "}) ==
             {:error, :selection_required}

    assert WonderFreeTextAnswer.capture(%{questions: []}, %{"freeText" => "hello"}) ==
             {:error, :selection_required}
  end

  defp request do
    %{
      request_id: "ask-1",
      parent_call_id: "parent-1",
      child_id: "child-1",
      questions: [
        %{id: "transport", kind: :choice, options: []},
        %{"id" => "scope", "kind" => "freeform", "options" => []}
      ]
    }
  end
end
