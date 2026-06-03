defmodule Ourocode.Runtime.OuroborosSkillCoverageTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.{
    InterviewWorkflowInvocation,
    LoopBindingWorkflowDispatch,
    OuroborosDirectInvocation,
    OuroborosWorkflowInvocation,
    RouteClassifier
  }

  @skill_routes %{
    "auto" => {"ooo auto improve routing", :auto, OuroborosWorkflowInvocation},
    "brownfield" => {"ooo brownfield scan", :brownfield, OuroborosWorkflowInvocation},
    "cancel" => {"ooo cancel execution exec-1", :cancel, OuroborosDirectInvocation},
    "evaluate" => {"ooo evaluate session sess-1", :evaluate, OuroborosWorkflowInvocation},
    "evolve" => {"ooo evolve --status lin-1", :evolve, OuroborosWorkflowInvocation},
    "help" => {"ooo help", :help, OuroborosDirectInvocation},
    "interview" => {"ooo interview clarify routing", :interview, InterviewWorkflowInvocation},
    "pm" => {"ooo pm write product requirements", :interview, InterviewWorkflowInvocation},
    "publish" => {"ooo publish seed.yaml", :publish, OuroborosDirectInvocation},
    "qa" => {"ooo qa artifact.md", :qa, OuroborosWorkflowInvocation},
    "ralph" => {"ooo ralph --lineage-id lin-1", :ralph, OuroborosWorkflowInvocation},
    "resume-session" => {"ooo resume-session", :resume_session, OuroborosDirectInvocation},
    "run" => {"ooo run seed.yaml", :run, OuroborosWorkflowInvocation},
    "seed" => {"ooo seed session sess-1", :seed, OuroborosWorkflowInvocation},
    "setup" => {"ooo setup", :setup, OuroborosDirectInvocation},
    "status" => {"ooo status session sess-1", :status, OuroborosWorkflowInvocation},
    "tutorial" => {"ooo tutorial", :tutorial, OuroborosDirectInvocation},
    "unstuck" => {"ooo unstuck routing is stuck", :lateral, OuroborosWorkflowInvocation},
    "update" => {"ooo update", :update, OuroborosDirectInvocation},
    "welcome" => {"ooo welcome", :welcome, OuroborosDirectInvocation}
  }

  @local_ouroboros_skills [
    "auto",
    "brownfield",
    "cancel",
    "evaluate",
    "evolve",
    "help",
    "interview",
    "pm",
    "publish",
    "qa",
    "ralph",
    "resume-session",
    "run",
    "seed",
    "setup",
    "status",
    "tutorial",
    "unstuck",
    "update",
    "welcome"
  ]

  test "coverage manifest accounts for every local Ouroboros control skill" do
    assert @skill_routes |> Map.keys() |> Enum.sort() == Enum.sort(@local_ouroboros_skills)
  end

  test "every Ouroboros control skill routes to a concrete workflow adapter" do
    registry = LoopBindingWorkflowDispatch.adapter_registry()

    Enum.each(@skill_routes, fn {skill, {input, expected_route, expected_adapter}} ->
      decision = RouteClassifier.routing_decision(input)

      assert decision.execution_route == :ouroboros_workflow, "#{skill} must not fall to default"
      assert decision.adapter_route == expected_route

      adapter =
        Map.get(registry, {:ouroboros_workflow, expected_route}) ||
          Map.get(registry, {:ouroboros, expected_route}) ||
          Map.get(registry, :"ouroboros_#{expected_route}")

      assert adapter == expected_adapter
    end)
  end
end
