defmodule Ourocode.Runtime.WonderAnswerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.WonderAnswer

  defp request do
    %{
      tool: :wonder_tool,
      type: :multiple_choice_decision,
      request_id: "ask-1",
      parent_call_id: "parent-1",
      child_id: "child-1",
      questions: [
        %{
          id: "transport",
          header: "Transport",
          question: "Which transport?",
          options: [
            %{label: "stdio", description: "local pipe"},
            %{label: "http", description: "remote stream"}
          ]
        },
        %{
          id: "scope",
          header: "Scope",
          question: "Which scope?",
          options: [
            %{label: "narrow", description: "one feature"},
            %{label: "broad", description: "whole module"}
          ]
        }
      ]
    }
  end

  test "captures one selection per question and combines handback text" do
    assert {:ok, combined} = WonderAnswer.capture(request(), [1, 2])

    assert combined.result.selected_label == "stdio; broad"
    assert combined.handback == "transport: stdio\nscope: broad"
    assert combined.token == "stdio; broad"
    assert Enum.map(combined.result.decisions, & &1.question_id) == ["transport", "scope"]
  end

  test "captures free text for a targeted question" do
    assert {:ok, combined} =
             WonderAnswer.capture(request(), %{
               "questionId" => "scope",
               "freeText" => "whole module with migration tests"
             })

    assert combined.result.question_id == "scope"
    assert combined.result.free_text == "whole module with migration tests"
    assert combined.handback == "whole module with migration tests"
  end

  test "preserves multi-select payload for a single multi-select question" do
    request = %{
      request()
      | questions: [
          %{
            id: "axes",
            header: "Axes",
            question: "Which axes?",
            multi_select?: true,
            options: [
              %{label: "Users", description: "grow adoption"},
              %{label: "Features", description: "complete core"},
              %{label: "Business", description: "make sustainable"}
            ]
          }
        ]
    }

    assert {:ok, combined} = WonderAnswer.capture(request, [1, 3])
    assert combined.result.multi_select? == true
    assert combined.result.selected_indices == [1, 3]
    assert combined.result.selected_label == "Users, Business"
  end

  test "builds acknowledgement and cancellation events from a detection" do
    request = %{request() | questions: [hd(request().questions)]}
    detection = %{parent_call_id: "parent-1", child_id: "child-1", request: request}
    {:ok, combined} = WonderAnswer.capture(request, 2)

    ack = WonderAnswer.ack_event(detection, combined)
    assert ack.source == :wonder_tool
    assert ack.parent_call_id == "parent-1"
    assert ack.child_id == "child-1"
    assert ack.payload.kind == :wonder_tool_answer
    assert ack.payload.question_id == "transport"
    assert ack.payload.token == "answered: http"

    cancelled = WonderAnswer.cancelled(detection, "  decline  ")
    assert cancelled == %{cancelled: true, reason: "decline", question_id: "transport"}

    cancel_event = WonderAnswer.cancel_event(detection, cancelled)
    assert cancel_event.payload.kind == :wonder_tool_cancelled
    assert cancel_event.payload.question_id == "transport"
    assert cancel_event.payload.token == "declined: decline"
  end
end
