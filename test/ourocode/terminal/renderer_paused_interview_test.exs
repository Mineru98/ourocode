defmodule Ourocode.Terminal.RendererPausedInterviewTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.RendererPausedInterview

  test "hides slash palette while a paused interview command is being typed" do
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

    assert updated == nil
  end

  test "hides cancel palette while a paused interview command is being typed" do
    palette = %{entries: [], index: 0}

    updated =
      RendererPausedInterview.palette(palette, "/canc", %{
        interview_paused: true,
        pidx: 0
      })

    assert updated == nil
  end

  test "hides palette when paused control text is ready to submit" do
    palette = %{entries: [%{slash: "/help", summary: "Help"}], index: 0}

    assert RendererPausedInterview.palette(palette, "/cancel", %{interview_paused: true}) == nil

    assert RendererPausedInterview.palette(palette, "/answer ship it", %{interview_paused: true}) ==
             nil
  end

  test "recognizes direct answer query while paused" do
    assert RendererPausedInterview.answer_query?("/answer")
    assert RendererPausedInterview.answer_query?("  /answer proceed")
    refute RendererPausedInterview.answer_query?("/answers")
  end

  test "recognizes cancel query while paused" do
    assert RendererPausedInterview.cancel_query?("/cancel")
    assert RendererPausedInterview.cancel_query?("  /cancel now")
    refute RendererPausedInterview.cancel_query?("/cancelled")
  end

  test "leaves palette unchanged outside paused interview mode" do
    palette = %{entries: [%{slash: "/help"}], index: 0}

    assert RendererPausedInterview.palette(palette, "/an", %{}) == palette
    assert RendererPausedInterview.palette(nil, "/an", %{interview_paused: true}) == nil
  end
end
