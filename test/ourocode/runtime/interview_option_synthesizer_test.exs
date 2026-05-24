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

  test "creates decision options when no candidates can be parsed" do
    options = InterviewOptionSynthesizer.options([], "What should this interview clarify?")

    assert Enum.map(options, & &1["label"]) == [
             "Narrow the scope",
             "Broaden the scope",
             "Prioritize release readiness"
           ]
  end
end
