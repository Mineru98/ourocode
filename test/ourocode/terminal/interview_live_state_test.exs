defmodule Ourocode.Terminal.InterviewLiveStateTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewLiveState

  test "reads interview values from the direct result" do
    result = %{
      interview: %{status: "waiting"},
      wonder_tool: %{request_id: "req-1"},
      interview_session: %{label: "ooo interview"},
      paused: true
    }

    assert InterviewLiveState.interview(result) == %{status: "waiting"}
    assert InterviewLiveState.wonder_tool(result) == %{request_id: "req-1"}
    assert InterviewLiveState.interview_session(result) == %{label: "ooo interview"}
    assert InterviewLiveState.paused?(result)
  end

  test "reads merged live pane snapshot values" do
    result = %{
      interview: %{status: "stale"},
      paused: false,
      pane_snapshot: fn -> %{interview: %{status: "live"}, paused: true} end
    }

    assert InterviewLiveState.interview(result) == %{status: "live"}
    assert InterviewLiveState.paused?(result)
  end

  test "ignores invalid or failing snapshots" do
    invalid = %{interview: %{status: "direct"}, pane_snapshot: fn -> :not_a_map end}
    failing = %{interview: %{status: "direct"}, pane_snapshot: fn -> raise "boom" end}

    assert InterviewLiveState.interview(invalid) == %{status: "direct"}
    assert InterviewLiveState.interview(failing) == %{status: "direct"}
    refute InterviewLiveState.paused?(invalid)
  end

  test "returns nil for malformed values" do
    result = %{interview: :bad, wonder_tool: [], interview_session: "session", paused: "true"}

    assert InterviewLiveState.interview(result) == nil
    assert InterviewLiveState.wonder_tool(result) == nil
    assert InterviewLiveState.interview_session(result) == nil
    refute InterviewLiveState.paused?(result)
  end
end
