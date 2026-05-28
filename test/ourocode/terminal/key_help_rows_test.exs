defmodule Ourocode.Terminal.KeyHelpRowsTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.KeyHelpRows

  test "rows prioritizes wonder picker controls" do
    rows = KeyHelpRows.rows(:normal, %{wonder_focus: true, interview_paused: true})

    assert {"Up/Dn j/k", "move option"} in rows
    assert {"Esc", "pause interview"} in rows
    refute {"/answer <text>", "submit to interview"} in rows
  end

  test "rows shows paused interview controls" do
    rows = KeyHelpRows.rows(:normal, %{interview_paused: true})

    assert rows == [
             {"/answer <text>", "submit to interview"},
             {"type normally", "discuss with main session"},
             {"Ctrl-G", "hide this help"}
           ]
  end

  test "rows switches palette controls while palette is open" do
    assert KeyHelpRows.rows(:palette, %{}) == [
             {"Up/Dn", "move"},
             {"Enter", "run"},
             {"Esc", "close"},
             {"Ctrl-G", "hide help"}
           ]
  end

  test "rows defaults to normal prompt controls" do
    rows = KeyHelpRows.rows(:normal, %{})

    assert {"/", "commands"} in rows
    assert {"@", "file mentions"} in rows
    assert {"Ctrl-A/E", "line start/end"} in rows
  end
end
