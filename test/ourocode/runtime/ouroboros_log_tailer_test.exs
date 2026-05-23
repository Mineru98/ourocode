defmodule Ourocode.Runtime.OuroborosLogTailerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Runtime.OuroborosLogTailer

  test "parses auto progress lines" do
    assert OuroborosLogTailer.parse_line("[auto] interview — starting auto interview") == [
             "auto: interview — starting auto interview"
           ]
  end

  test "parses structured interview question logs into readable activity" do
    line =
      "2026-05-21T18:56:42.260163Z [info     ] interview.question_generated filename=interview.py interview_id=interview_1 lineno=520 question_length=133 round_number=1"

    assert OuroborosLogTailer.parse_line(line) == [
             "round 1 · question generated · 133 chars"
           ]
  end

  test "parses interview start and MCP handoff logs into readable activity" do
    assert OuroborosLogTailer.parse_line(
             "2026-05-22T07:03:12.980497Z [info     ] interview.started filename=interview.py initial_context_length=39 interview_id=interview_20260522_070312 is_brownfield=True lineno=392"
           ) == ["interview started · session 20260522_070312 · 39 chars · brownfield"]

    assert OuroborosLogTailer.parse_line(
             "2026-05-22T07:03:18.641121Z [info     ] mcp.tool.interview.started filename=authoring_handlers.py lineno=1932 session_id=interview_20260522_070312"
           ) == ["mcp interview started · session 20260522_070312"]
  end

  test "parses answer recorded logs into readable activity" do
    line =
      "2026-05-21T18:56:48.345680Z [info     ] interview.response_recorded filename=interview.py interview_id=interview_1 lineno=583 response_length=208 round_number=2"

    assert OuroborosLogTailer.parse_line(line) == [
             "round 2 · answer recorded · 208 chars"
           ]
  end

  test "ignores unrelated server registration noise" do
    line =
      "2026-05-21T18:59:19.387512Z [info     ] mcp.registry.tool_registered filename=registry.py tool=ouroboros_interview"

    assert OuroborosLogTailer.parse_line(line) == []
  end

  test "tails only new log entries after the saved offset" do
    path =
      Path.join(System.tmp_dir!(), "ourocode-log-tail-#{System.unique_integer([:positive])}.log")

    on_exit(fn -> File.rm(path) end)

    File.write!(path, "[auto] created — created\n")
    offsets = %{path => OuroborosLogTailer.file_size(path)}
    File.write!(path, "[auto] interview — round 1\n", [:append])

    assert {["auto: interview — round 1"], %{^path => offset}} =
             OuroborosLogTailer.tail([path], offsets)

    assert offset == OuroborosLogTailer.file_size(path)
  end
end
