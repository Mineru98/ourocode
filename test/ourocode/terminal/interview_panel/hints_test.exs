defmodule Ourocode.Terminal.InterviewPanel.HintsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.Hints

  test "marker names active and paused interview blocks" do
    assert Hints.marker(false) == "INTERVIEW"
    assert Hints.marker(true) == "INTERVIEW (paused)"
  end

  test "session hint reflects whether the interview is paused" do
    assert Hints.session_hint(false) ==
             "running   the main session is handling this   stays until it ends"

    assert Hints.session_hint(true) ==
             "paused   type to talk to main   /answer <answer> submits to interview"
  end

  test "wonder hint separates paused, picker, and plain interview states" do
    assert Hints.wonder_hint(true, false) ==
             "type to talk to main session   answers resume the interview"

    assert Hints.wonder_hint(false, true) ==
             "1-9 select   type free answer   /cancel decline   Esc pause"

    assert Hints.wonder_hint(false, false) == "type your answer + Enter   Esc pause"
  end

  test "wonder picker hint reflects pause state and question count" do
    assert Hints.wonder_pick_hint(true, 2) ==
             "type to talk to main   /answer <answer> submits to interview"

    assert Hints.wonder_pick_hint(false, 2) ==
             "Up/Dn pick   Tab next question   Free answer row   Enter submit all   Esc pause"

    assert Hints.wonder_pick_hint(false, 1) ==
             "Up/Dn pick   1-9 shortcut   Free answer row   Enter submit   Esc pause"
  end
end
