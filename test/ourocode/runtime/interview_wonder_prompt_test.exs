defmodule Ourocode.Runtime.InterviewWonderPromptTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewWonderPrompt

  test "event builds the wonderTool checkpoint shape for a user-routed interview question" do
    event =
      InterviewWonderPrompt.event("parent-1", 3, "**Choose**: stdio or http?", [
        %{label: "stdio", description: "local pipe"}
      ])

    assert event.type == :child_event
    assert event.source == :wonder_tool
    assert event.parent_call_id == "parent-1"
    assert event.payload["tool"] == "wonderTool"
    assert event.payload["request_id"] == "parent-1-ask-3"

    assert [
             %{
               "id" => "interview",
               "header" => "Interview",
               "round" => 3,
               "question" => "Choose: stdio or http?",
               "options" => options
             }
           ] = event.payload["questions"]

    assert Enum.at(options, 0) == %{"label" => "stdio", "description" => "local pipe"}
    assert Enum.at(options, 1)["label"] == "Define the desired outcome"
  end

  test "options preserve model choices first and pad to the wonderTool minimum" do
    assert [
             %{"label" => "A", "description" => "alpha"},
             %{"label" => "Define the desired outcome"}
           ] =
             InterviewWonderPrompt.options([%{label: :A, description: :alpha}], "ignored")
  end

  test "options derive candidate hints from prompts when model is silent" do
    english = InterviewWonderPrompt.options([], "Which target: docs, tests, or runtime?")

    assert Enum.map(english, & &1["label"]) == ["docs", "tests", "runtime"]
  end

  test "options derive comma-only hints only when the prompt has an actual list" do
    options = InterviewWonderPrompt.options([], "Choose deployment target: local, staging, prod")

    assert Enum.map(options, & &1["label"]) == ["local", "staging", "prod"]
  end

  test "options fall back to decision affordances when no candidates exist" do
    assert [
             %{"label" => "Define the desired outcome"},
             %{"label" => "Clarify the target user"}
           ] = InterviewWonderPrompt.options([], "What should we do next?")
  end

  test "options do not split free-form questions into fake choices" do
    options =
      InterviewWonderPrompt.options(
        [],
        "For first-time setup, who is the primary user persona and what outcome should they reach?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Clarify the first priority",
             "Define the success criteria"
           ]
  end
end
