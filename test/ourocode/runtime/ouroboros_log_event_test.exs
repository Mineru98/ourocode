defmodule Ourocode.Runtime.OuroborosLogEventTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosLogEvent

  test "formats interview lifecycle events" do
    assert OuroborosLogEvent.format("info", "interview.started", %{
             "initial_context_length" => "39",
             "interview_id" => "interview_20260522_070312",
             "is_brownfield" => "True"
           }) == "interview started · session 20260522_070312 · 39 chars · brownfield"

    assert OuroborosLogEvent.format("info", "interview.question_generated", %{
             "question_length" => "133",
             "round_number" => "1"
           }) == "round 1 · question generated · 133 chars"
  end

  test "formats MCP interview errors with level prefix" do
    assert OuroborosLogEvent.format("error", "mcp.tool.interview.error", %{
             "error" => "network failed"
           }) == "error: mcp interview error · network failed"
  end

  test "formats fallback events and drops noisy file metadata" do
    line =
      OuroborosLogEvent.format("warning", "seed.generated", %{
        "filename" => "seed.py",
        "lineno" => "10",
        "seed_id" => "seed_1",
        "run_id" => "run_1"
      })

    assert line =~ "warning: seed.generated"
    assert line =~ "seed_id seed_1"
    assert line =~ "run_id run_1"
    refute line =~ "filename"
    refute line =~ "lineno"
  end
end
