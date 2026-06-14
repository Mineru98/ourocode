defmodule Ourocode.Runtime.InterviewWonderPromptTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewWonderPrompt
  alias Ourocode.WonderTool.InteractionDetector

  test "event builds the wonderTool checkpoint shape for a user-routed interview question" do
    event =
      InterviewWonderPrompt.event("parent-1", 3, "**Choose**: stdio or http?", [
        %{label: "stdio", description: "local pipe"},
        %{label: "http", description: "streamable transport"}
      ])

    assert event.type == :child_event
    assert event.source == :wonder_tool
    assert event.parent_call_id == "parent-1"
    assert event.payload["tool"] == "wonderTool"
    assert event.payload["type"] == "multiple_choice_decision"
    assert event.payload["interaction_kind"] == "socratic"
    assert event.payload["request_id"] == "parent-1-ask-3"

    assert [
             %{
               "id" => "interview",
               "header" => "Interview",
               "kind" => "socratic",
               "round" => 3,
               "question" => "Choose: stdio or http?",
               "options" => options
             }
           ] = event.payload["questions"]

    assert options == [
             %{"label" => "stdio", "description" => "local pipe"},
             %{"label" => "http", "description" => "streamable transport"}
           ]

    assert {:ok, %{checkpoint_kinds: [:socratic], option_counts: [2]}} =
             InteractionDetector.detect(event.payload)
  end

  test "options preserve supplied choices without local padding" do
    assert [
             %{"label" => "Alpha", "description" => "alpha"},
             %{"label" => "Beta", "description" => "beta"}
           ] =
             InterviewWonderPrompt.options(
               [
                 %{"label" => "Alpha", "description" => "alpha"},
                 %{"label" => "Beta", "description" => "beta"}
               ],
               "ignored"
             )
  end

  test "options do not derive local candidates from prompts when model is silent" do
    english = InterviewWonderPrompt.options([], "Which target: docs, tests, or runtime?")

    assert english == []
  end

  test "options do not derive comma-only hints from prompt text" do
    options = InterviewWonderPrompt.options([], "Choose deployment target: local, staging, prod")

    assert options == []
  end

  test "options do not fall back to generic decision affordances" do
    assert [] = InterviewWonderPrompt.options([], "What should we do next?")
  end

  test "options leave free-form questions without choices" do
    options =
      InterviewWonderPrompt.options(
        [],
        "For first-time setup, who is the primary user persona and what outcome should they reach?"
      )

    assert options == []
  end
end
