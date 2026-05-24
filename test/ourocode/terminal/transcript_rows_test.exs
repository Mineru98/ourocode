defmodule Ourocode.Terminal.TranscriptRowsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TranscriptRows

  test "rows convert user and assistant activity into labelled railed blocks" do
    rows = TranscriptRows.rows(["you> hello", "still user", "ourocode> hi", "still assistant"])

    assert [
             %{rail: nil, text: "YOU", text_style: :label},
             %{rail: "|", rail_style: :accent, text: "hello", text_style: :strong},
             %{rail: "|", rail_style: :accent, text: "still user", text_style: :strong},
             %{rail: nil, text: "", text_style: :text},
             %{rail: nil, text: "OUROCODE", text_style: :label},
             %{rail: "|", rail_style: :dim, text: "hi", text_style: :text},
             %{rail: "|", rail_style: :dim, text: "still assistant", text_style: :text}
           ] = rows
  end

  test "rows render system events separately and humanize SSoT frame content" do
    rows =
      TranscriptRows.rows([
        "+-- Plugin Status (1) region=plugin_status x=0 y=0 w=80 h=4",
        "| [OFFICIAL] id=plugin-a state=loaded",
        "+--",
        "queued task task_1"
      ])

    assert Enum.map(rows, & &1.text) == [
             "-- OFFICIAL plugin-a loaded",
             "",
             "-- queued task task_1"
           ]

    assert Enum.all?(rows, &(&1.rail == nil))
  end

  test "paused_interview_discussion keeps only the local user-assistant discussion" do
    activity = [
      "empty",
      "[workflow-starting] dispatching_input task=task_1",
      "queued task task_1: ooo interview",
      "-- interview paused (type to talk to main session)",
      "-- model: codex",
      "status=healthy runtime=ready",
      "you> 한글로 얘기해줘",
      "계속 같은 사용자 발화",
      "ourocode> 네, 한글로 이야기하겠습니다.",
      "계속 같은 답변",
      "workflow resumed"
    ]

    assert TranscriptRows.paused_interview_discussion(activity) == [
             "you> 한글로 얘기해줘",
             "계속 같은 사용자 발화",
             "ourocode> 네, 한글로 이야기하겠습니다.",
             "계속 같은 답변"
           ]
  end
end
