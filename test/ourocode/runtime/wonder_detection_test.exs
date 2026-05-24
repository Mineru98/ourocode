defmodule Ourocode.Runtime.WonderDetectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.WonderDetection

  test "stores wonderTool detections from event payloads" do
    state = %{wonder: nil}

    event = %{
      payload: %{
        "tool" => "wonderTool",
        "arguments" => %{
          "requestId" => "wt-1",
          "childID" => "child-wt-1",
          "parentCallId" => "parent-wt-1",
          "questions" => [
            %{
              "id" => "choice",
              "header" => "Choice",
              "question" => "Pick one",
              "options" => [
                %{"label" => "A", "description" => "First"},
                %{"label" => "B", "description" => "Second"}
              ]
            }
          ]
        }
      }
    }

    assert %{wonder: %{tool: :wonder_tool, question_count: 1}} =
             WonderDetection.apply(state, event)
  end

  test "leaves state unchanged when no interaction is present" do
    state = %{wonder: %{existing: true}}

    assert WonderDetection.apply(state, %{payload: %{token: "plain"}}) == state
  end
end
