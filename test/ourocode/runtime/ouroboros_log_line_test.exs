defmodule Ourocode.Runtime.OuroborosLogLineTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosLogLine

  test "parses auto progress lines" do
    assert OuroborosLogLine.parse("[auto] interview — starting auto interview") == [
             "auto: interview — starting auto interview"
           ]
  end

  test "parses structured interview lifecycle lines" do
    assert OuroborosLogLine.parse(
             "2026-05-22T07:03:12Z [info] interview.started initial_context_length=39 interview_id=interview_20260522_070312 is_brownfield=True"
           ) == ["interview started · session 20260522_070312 · 39 chars · brownfield"]

    assert OuroborosLogLine.parse(
             "2026-05-22T07:03:13Z [info] interview.question_generated question_length=133 round_number=1"
           ) == ["round 1 · question generated · 133 chars"]

    assert OuroborosLogLine.parse(
             "2026-05-22T07:03:14Z [info] interview.response_recorded response_length=208 round_number=2"
           ) == ["round 2 · answer recorded · 208 chars"]
  end

  test "parses MCP interview handoff and error lines" do
    assert OuroborosLogLine.parse(
             "2026-05-22T07:03:18Z [info] mcp.tool.interview.started session_id=interview_20260522_070312"
           ) == ["mcp interview started · session 20260522_070312"]

    assert OuroborosLogLine.parse(
             "2026-05-22T07:03:19Z [error] mcp.tool.interview.error error='network failed'"
           ) == ["error: mcp interview error · network failed"]
  end

  test "formats fallback interesting events and ignores unrelated noise" do
    assert [line] =
             OuroborosLogLine.parse(
               "2026-05-22T07:03:20Z [warning] seed.generated filename=seed.py seed_id=seed_1 run_id=run_1"
             )

    assert line =~ "warning: seed.generated"
    assert line =~ "seed_id seed_1"
    assert line =~ "run_id run_1"

    assert OuroborosLogLine.parse(
             "2026-05-21T18:59:19Z [info] mcp.registry.tool_registered tool=ouroboros_interview"
           ) == []
  end

  test "strips ansi control codes and ignores blanks" do
    assert OuroborosLogLine.parse("\e[31m[auto] created\e[0m") == ["auto: created"]
    assert OuroborosLogLine.parse("   ") == []
    assert OuroborosLogLine.parse(nil) == []
  end
end
