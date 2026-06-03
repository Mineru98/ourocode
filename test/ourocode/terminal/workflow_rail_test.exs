defmodule Ourocode.Terminal.WorkflowRailTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{FrameSections, WorkflowRail}

  test "summarizes the compact deep-interview-plan-execute-verify-evidence method" do
    sections =
      FrameSections.parse("""
      +-- Parent/Child Sessions region=runtime_panes layout=terminal_split
      | parent MCP toolcall ouroboros__ralph · streaming · 2 child panes
      | child session-a · working · parent=parent-1
      |   + [streaming] Tool ouroboros__evolve_step arguments
      | child session-b · working · parent=parent-1
      |   + [completed] Tool ouroboros__qa QA passed
      +--
      """)

    assert WorkflowRail.rows(sections, ["ambiguity 0.12"], []) == [
             "● deep-interview live",
             "● plan warming",
             "● execute live",
             "● verify active",
             "● evidence recorded"
           ]
  end

  test "prefers workflow run control state over inferred section text" do
    workflow = %{
      latest_run_id: "workflow-run:parent-1",
      runs: %{
        "workflow-run:parent-1" => %{
          status: :completed,
          adapter_route: :run,
          evidence: [%{kind: :seed_artifact}]
        }
      }
    }

    assert WorkflowRail.rows([], [], [], workflow) == [
             "● deep-interview ready",
             "● plan ready",
             "● execute done",
             "● verify ready",
             "● evidence recorded"
           ]
  end
end
