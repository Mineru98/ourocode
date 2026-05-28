defmodule Ourocode.Terminal.LiveTurnActivityTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.LiveTurnActivity

  test "renders truthful lifecycle pulses for guided commands" do
    event = %{
      prompt_state: :awaiting_prompt,
      task_input: "ooo auto improve startup flow"
    }

    assert LiveTurnActivity.view(event, 0) == [
             "live: auto is preparing the plan",
             "  activity: ■⬝⬝ waiting for the first visible update",
             "  pulse: waiting for the next update"
           ]

    assert LiveTurnActivity.view(event, 1) == [
             "live: auto is preparing the plan",
             "  activity: ■■⬝ waiting for the first visible update",
             "  pulse: watching for first question"
           ]
  end

  test "stays silent for unrelated lifecycle events" do
    assert LiveTurnActivity.view(%{prompt_state: :idle}, 0) == []
    assert LiveTurnActivity.view(nil, 0) == []
  end
end
