defmodule Ourocode.Terminal.RendererInterviewTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererInterview, Screen}

  test "draw_focus owns the panel and renders selected-option prompt" do
    block =
      {"INTERVIEW",
       [
         "Question 1/1",
         "Which behavior should change?",
         ">> [1] Navigation - move through options",
         "   [2] Visual focus - dim everything else"
       ], "Enter submit   Esc pause"}

    screen =
      Screen.new(80, 18)
      |> RendererInterview.draw_focus(80, 3, 14, block, "custom answer")

    text =
      screen
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "INTERVIEW"
    assert text =~ "● >> [1] Navigation"
    assert text =~ "Custom answer: custom answer"
    assert text =~ "Enter confirm"
    assert cell_style(screen, 0, 3) == :p_fill
    assert cell_style(screen, 79, 14) == :p_fill

    blank_text =
      Screen.new(80, 18)
      |> RendererInterview.draw_focus(80, 3, 14, block, "")
      |> Screen.to_lines()
      |> Enum.join("\n")

    refute blank_text =~ "Select an answer"
    assert blank_text =~ "Enter confirm"

    command_text =
      Screen.new(80, 18)
      |> RendererInterview.draw_focus(80, 3, 14, block, "/cancel")
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert command_text =~ "Command: /cancel"
    refute command_text =~ "Custom answer: /cancel"
  end

  test "draw_focus wraps continuation lines without clipping word endings" do
    question =
      "What exactly should validate plugin install flow prove: that installation succeeds end-to-end for a real plugin, that failed installs produce correct errors and rollback behavior, or that the requirements flow is valid?"

    block =
      {"INTERVIEW",
       [
         question,
         ">> [1] installation succeeds end-to-end for a real plugin",
         "   [2] failed installs produce correct errors and rollback behavior"
       ], "Enter submit   Esc pause"}

    text =
      Screen.new(80, 20)
      |> RendererInterview.draw_focus(80, 3, 16, block, "")
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "failed installs"
    refute text =~ "failed instal "
  end

  test "draw_focus uses compact hints on narrow terminals" do
    block =
      {"INTERVIEW",
       [
         "Which target user should the plugin onboarding serve?",
         ">> [1] Existing Codex users",
         "   [2] First-time installers"
       ], "type custom answer"}

    text =
      Screen.new(60, 18)
      |> RendererInterview.draw_focus(60, 3, 14, block, "")
      |> Screen.to_lines()
      |> Enum.join("\n")

    refute text =~ "Select an answer"
    assert text =~ "Enter confirm"
    refute text =~ "Type for custo"
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
    assert text =~ "│ INTERVIEW"
    assert text =~ "│ Question"
    assert text =~ "│ ● >> [1] answer"
    assert text =~ "│ type answer"
  end

  test "draw_block wraps long logical lines with continuation indentation" do
    long = "This is a very long interview question that needs to wrap into multiple rows"

    {screen, used} =
      Screen.new(36, 12)
      |> RendererInterview.draw_block(1, 32, "INTERVIEW", [long], "hint", 8)

    lines = Screen.to_lines(screen)

    assert used > 3
    assert Enum.any?(lines, &String.contains?(&1, "This is a very long"))
    assert Enum.any?(lines, &String.contains?(&1, "│   interview question"))
  end

  test "wrap_text delegates hard-splitting for narrow widths" do
    assert RendererInterview.wrap_text("abcdef", 2) == ["ab", "cd", "ef"]
  end

  defp cell_style(%{rows: rows}, x, y) do
    case get_in(rows, [y, x]) do
      {:cont, style} -> style
      {text, style} when is_binary(text) -> style
      nil -> nil
    end
  end
end
