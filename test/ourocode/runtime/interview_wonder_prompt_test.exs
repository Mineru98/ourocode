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
               "question" => "Choose: stdio or http?",
               "options" => options
             }
           ] = event.payload["questions"]

    assert Enum.at(options, 0) == %{"label" => "stdio", "description" => "local pipe"}
    assert Enum.at(options, 1)["label"] == "Answer in my own words"
  end

  test "options preserve model choices first and pad to the wonderTool minimum" do
    assert [
             %{"label" => "A", "description" => "alpha"},
             %{"label" => "Answer in my own words"}
           ] =
             InterviewWonderPrompt.options([%{label: :A, description: :alpha}], "ignored")
  end

  test "options derive candidate hints from English and Korean prompts when model is silent" do
    english = InterviewWonderPrompt.options([], "Which target: docs, tests, or runtime?")

    assert Enum.map(english, & &1["label"]) == ["docs", "tests", "runtime?"]

    korean = InterviewWonderPrompt.options([], "어느 쪽을 먼저 볼까요? 라우팅 아니면 렌더링")

    assert Enum.map(korean, & &1["label"]) == ["라우팅", "렌더링"]
  end

  test "options fall back to generic affordances when no candidates exist" do
    assert [
             %{"label" => "Answer in my own words"},
             %{"label" => "Not sure — skip for now"}
           ] = InterviewWonderPrompt.options([], "What should we do next?")
  end
end
