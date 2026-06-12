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

  test "build prunes an older oversized observation but keeps the newest verbatim" do
    old = String.duplicate("a", 30_000)

    prompt =
      Prompt.build(
        "What is the entrypoint?",
        [
          {"READ big.txt", old},
          {"GREP main_module", "main_module: Ourocode.CLI"}
        ],
        3
      )

    refute prompt =~ old
    assert prompt =~ "### READ big.txt\n[pruned 30000-byte output"
    assert prompt =~ "### GREP main_module\nmain_module: Ourocode.CLI"
  end

  test "build keeps the newest observation and small older ones even over budget" do
    huge = String.duplicate("b", 30_000)

    prompt =
      Prompt.build(
        "Q",
        [
          {"READ small.txt", "old but tiny"},
          {"READ huge.txt", huge}
        ],
        2
      )

    # The newest observation always survives in full; pruning a tiny older
    # one would save nothing, so it survives too.
    assert prompt =~ huge
    assert prompt =~ "### READ small.txt\nold but tiny"
    refute prompt =~ "[pruned"
  end
end
