defmodule Ourocode.Terminal.RendererPausedInterviewTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RendererPausedInterview

  test "adds answer entry to paused interview palette" do
    palette = %{
      entries: [
        %{slash: "/help", summary: "Help"},
        %{slash: "/answer", summary: "Old answer"}
      ],
      index: 0
    }

    updated =
      RendererPausedInterview.palette(palette, "/an", %{
        interview_paused: true,
        pidx: 4
      })

    assert [%{slash: "/answer", summary: summary}, %{slash: "/help"}] = updated.entries
    assert summary =~ "submits to the interview"
    assert updated.index == 0
  end

  test "recognizes direct answer query while paused" do
    assert RendererPausedInterview.answer_query?("/answer")
    assert RendererPausedInterview.answer_query?("  /answer proceed")
    refute RendererPausedInterview.answer_query?("/answers")
  end

  test "leaves palette unchanged outside paused interview mode" do
    palette = %{entries: [%{slash: "/help"}], index: 0}

    assert RendererPausedInterview.palette(palette, "/an", %{}) == palette
    assert RendererPausedInterview.palette(nil, "/an", %{interview_paused: true}) == nil
  end
end
