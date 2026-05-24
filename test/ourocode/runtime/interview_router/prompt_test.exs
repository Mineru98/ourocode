defmodule Ourocode.Runtime.InterviewRouter.PromptTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.InterviewRouter.Prompt

  test "build includes routing rules, turn budget, and reply contract" do
    prompt = Prompt.build("What stack does this project use?", [], 2)

    assert prompt =~ "## MCP question (turn 2/#{Prompt.max_turns()})"
    assert prompt =~ "What stack does this project use?"
    assert prompt =~ "Factual question about the EXISTING stack"
    assert prompt =~ "Goals, vision, acceptance criteria"
    assert prompt =~ "Output exactly one directive as the first line"
    refute prompt =~ "## Tool observations so far"
  end

  test "build renders accumulated tool observations in order" do
    prompt =
      Prompt.build(
        "What is the entrypoint?",
        [
          {"READ mix.exs", "def project do"},
          {"GREP main_module", "main_module: Ourocode.CLI"}
        ],
        3
      )

    assert prompt =~ "## Tool observations so far"
    assert prompt =~ "### READ mix.exs\ndef project do"
    assert prompt =~ "### GREP main_module\nmain_module: Ourocode.CLI"
  end
end
