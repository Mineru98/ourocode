defmodule Ourocode.Terminal.RendererInterviewTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererInterview, Screen}

  test "draw_focus owns the panel and renders free-answer prompt" do
    block =
      {"INTERVIEW",
       [
         "Question 1/1",
         "Which behavior should change?",
         ">> [1] Navigation - move through options",
         "   [2] Visual focus - dim everything else"
       ], "Enter submit   Esc pause"}

    text =
      Screen.new(80, 18)
      |> RendererInterview.draw_focus(80, 3, 14, block, "custom answer")
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ ">> [1] Navigation"
    assert text =~ "Free answer: custom answer"
    assert text =~ "Esc main session"
  end

  test "draw_block returns used rows and renders rail, marker, body, and hint" do
    {screen, used} =
      Screen.new(80, 12)
      |> RendererInterview.draw_block(
        2,
        70,
        "INTERVIEW",
        ["Question", ">> [1] answer"],
        "type answer",
        5
      )

    text = screen |> Screen.to_lines() |> Enum.join("\n")

    assert used == 4
    assert text =~ "| INTERVIEW"
    assert text =~ "| Question"
    assert text =~ "| >> [1] answer"
    assert text =~ "| type answer"
  end

  test "draw_block wraps long logical lines with continuation indentation" do
    long = "This is a very long interview question that needs to wrap into multiple rows"

    {screen, used} =
      Screen.new(36, 12)
      |> RendererInterview.draw_block(1, 32, "INTERVIEW", [long], "hint", 8)

    lines = Screen.to_lines(screen)

    assert used > 3
    assert Enum.any?(lines, &String.contains?(&1, "This is a very long"))
    assert Enum.any?(lines, &String.contains?(&1, "|   interview question"))
  end

  test "wrap_text delegates hard-splitting for narrow widths" do
    assert RendererInterview.wrap_text("abcdef", 2) == ["ab", "cd", "ef"]
  end
end
