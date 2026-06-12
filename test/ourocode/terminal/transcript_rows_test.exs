defmodule Ourocode.Terminal.TranscriptRowsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.TranscriptRows

  test "rows convert user and assistant activity into labelled railed blocks" do
    rows = TranscriptRows.rows(["you> hello", "still user", "ourocode> hi", "still assistant"])

    assert [
             %{rail: nil, text: "Answer", text_style: :accent},
             %{rail: "│", rail_style: :accent, text: "hello", text_style: :strong},
             %{rail: "│", rail_style: :accent, text: "still user", text_style: :strong},
             %{rail: nil, text: "", text_style: :text},
             %{rail: nil, text: "OUROCODE", text_style: :brand},
             %{rail: "│", rail_style: :brand, text: "hi", text_style: :text},
             %{rail: "│", rail_style: :brand, text: "still assistant", text_style: :text}
           ] = rows
  end

  test "rows render system events separately and humanize SSoT frame content" do
    rows =
      TranscriptRows.rows([
        "plugins: 1 available",
        "  [OFFICIAL] plugin-a - Official plugin - loaded",
        "task: queued task_1"
      ])

    assert Enum.map(rows, & &1.text) == [
             "• plugins: 1 available",
             "",
             "• OFFICIAL plugin-a - Official plugin - loaded",
             "",
             "• task: queued task_1"
           ]

    assert Enum.all?(rows, &(&1.rail == nil))
  end

  test "rows render clean interaction statuses without system bullets" do
    rows =
      TranscriptRows.rows([
        "Interview cancelled.",
        "Command held. Press Esc to discuss, or /cancel to stop this interview."
      ])

    assert [
             %{rail: "│", text: "Interview cancelled.", text_style: :strong},
             %{text: ""},
             %{
               rail: "│",
               text: "Command held. Press Esc to discuss, or /cancel to stop this interview.",
               text_style: :strong
             }
           ] = rows

    refute Enum.any?(rows, &String.starts_with?(&1.text, "• "))
  end

  test "paused_interview_discussion keeps only the local user-assistant discussion" do
    activity = [
      "empty",
      "[workflow-starting] dispatching_input task=task_1",
      "task: queued task_1: ooo interview",
      "-- interview paused (type normally to discuss; /answer <text> resumes)",
      "-- model: codex",
      "status=healthy runtime=ready",
      "you> discuss this first",
      "continued user note",
      "ourocode> I will discuss it before answering.",
      "continued assistant note",
      "workflow resumed"
    ]

    assert TranscriptRows.paused_interview_discussion(activity) == [
             "you> discuss this first",
             "continued user note",
             "ourocode> I will discuss it before answering.",
             "continued assistant note"
           ]
  end

  test "rows render workspace text as a selected record and detail panel" do
    rows =
      TranscriptRows.rows([
        "Plugins",
        "ready; 1 installed plugin",
        "Work",
        "  >> Guided workflows - loaded · ready",
        "Focus",
        "  role · guided work",
        "Open /verify",
        "Use Up/Dn rows; Enter inspect; type to compose"
      ])

    assert Enum.map(rows, & &1.text) == [
             "Plugins",
             "ready; 1 installed plugin",
             "Work",
             ">> Guided workflows - loaded · ready",
             "Focus",
             "",
             "role · guided work",
             "",
             "• Open /verify",
             "",
             "• Use Up/Dn rows; Enter inspect; type to compose"
           ]

    assert Enum.any?(
             rows,
             &(&1.text == ">> Guided workflows - loaded · ready" and &1.rail == "│")
           )

    refute Enum.any?(rows, &String.starts_with?(&1.text, "• Plugins"))
  end
end
