defmodule Ourocode.Runtime.InterviewOptionSynthesizerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewOptionSynthesizer

  test "prefers model supplied options before generic rows" do
    options =
      InterviewOptionSynthesizer.options(
        [
          %{label: "Reliability", description: "Fix breakage first"},
          %{"label" => "Packaging", "description" => "Focus on distribution"}
        ],
        "What should happen next?"
      )

    assert Enum.map(options, & &1["label"]) == ["Reliability", "Packaging"]
  end

  test "derives prompt candidate options when the prompt names tradeoffs" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Should we focus on terminal polish, plugin install flow, or release packaging?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "terminal polish",
             "plugin install flow",
             "release packaging"
           ]
  end

  test "creates decision-oriented options when no candidates can be parsed" do
    options = InterviewOptionSynthesizer.options([], "What should this interview clarify?")

    assert Enum.map(options, & &1["label"]) == [
             "Define the desired outcome",
             "Clarify the target user"
           ]
  end

  test "does not turn sentence fragments into fake picker choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What should the install flow prove: that a plugin can be discovered, installed, enabled, and used successfully end-to-end?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Define the desired outcome",
             "Clarify the target user"
           ]
  end

  test "creates onboarding-specific fallbacks for broad onboarding prompts" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Who is the onboarding for, and what outcome should a successfully onboarded user reach?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Define the target user",
             "Define the activation outcome",
             "Audit the existing flow"
           ]
  end

  test "creates audience-specific onboarding choices without repeating broad fallbacks" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Which onboarding audience should we serve first?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Existing agent users",
             "First-time plugin installers",
             "Internal builders"
           ]

    refute Enum.any?(options, &(&1["label"] == "Define the target user"))
  end

  test "creates completion-signal onboarding choices without repeating audience fallbacks" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What completion signal proves onboarding worked?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "First guided run succeeds",
             "Plugin tools verify cleanly",
             "Next action is obvious"
           ]

    refute Enum.any?(options, &(&1["label"] == "Define the activation outcome"))
  end

  test "does not append broad onboarding fallbacks when parsed choices are specific" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Should onboarding generate the smallest valid plugin structure or guide through template choice first?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "generate the smallest valid plugin structure",
             "guide through template choice first"
           ]
  end

  test "creates plugin scaffold fallbacks when no explicit options are present" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What plugin structure should the onboarding create?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Generate plugin structure",
             "Clarify plugin behavior"
           ]
  end

  test "creates workflow readiness fallbacks instead of repeating generic choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Which core workflows must be proven end-to-end for the plugin readiness test, and what is the expected successful outcome for each one?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Guided work starts and advances",
             "Plugin management views work",
             "Verification passes cleanly"
           ]
  end

  test "creates MCP tool readiness fallbacks when availability is the question" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "Are MCP tools available for the plugin, and what should ready mean?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "Plugin is loaded",
             "Tools are callable"
           ]
  end

  test "turns repeated dependent clauses into concrete picker choices" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "What should the install flow prove: that installation succeeds end-to-end for a real plugin, that failure cases produce correct diagnostics, that the UX/spec is complete, or that existing code/tests cover the flow?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "installation succeeds end-to-end for a real plugin",
             "failure cases produce correct diagnostics",
             "the UX/spec is complete",
             "existing code/tests cover the flow"
           ]
  end

  test "drops leading context when parsing comma-separated interview axes" do
    options =
      InterviewOptionSynthesizer.options(
        [],
        "For progress visibility, should the interview clarify current phase names, done criteria, or failure causes first?"
      )

    assert Enum.map(options, & &1["label"]) == [
             "current phase names",
             "done criteria",
             "failure causes first"
           ]
  end
end
