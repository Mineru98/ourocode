defmodule Ourocode.Terminal.InterviewPanel.HintsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Hints

  test "marker names active and paused interview blocks" do
    assert Hints.marker(false) == "INTERVIEW"
    assert Hints.marker(true) == "INTERVIEW (paused)"
  end

  test "session hint reflects whether the interview is paused" do
    assert Hints.session_hint(false) ==
             "drafting question"

    assert Hints.session_hint(true) ==
             "paused   /answer <answer> resumes   /cancel stops interview"
  end

  test "wonder hint separates paused, picker, and plain interview states" do
    assert Hints.wonder_hint(true, false) ==
             "paused   /answer <text> resumes   /cancel stops interview"

    assert Hints.wonder_hint(false, true) ==
             "/cancel stops"

    assert Hints.wonder_hint(false, false) == "plain answer"
  end

  test "wonder picker hint reflects pause state and question count" do
    assert Hints.wonder_pick_hint(true, 2) ==
             "paused   /answer <text> resumes   /cancel stops interview"

    assert Hints.wonder_pick_hint(false, 2) ==
             "Tab switches question"

    assert Hints.wonder_pick_hint(false, 1) ==
             ""
  end
end
