defmodule Ourocode.Terminal.RendererTranscriptTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererTranscript, Screen}

  test "draws centered empty-state hint when requested" do
    lines =
      Screen.new(60, 10)
      |> RendererTranscript.draw(60, 1, 8, [], true, 0)
      |> Screen.to_lines()

    assert Enum.any?(lines, &String.contains?(&1, "ourocode"))

    assert Enum.any?(lines, &String.contains?(&1, "Choose a start mode"))
    assert Enum.any?(lines, &String.contains?(&1, "pm"))
    assert Enum.any?(lines, &String.contains?(&1, "interview"))
    assert Enum.any?(lines, &String.contains?(&1, "auto"))
    assert Enum.any?(lines, &String.contains?(&1, "/ for commands"))
    refute Enum.any?(lines, &String.contains?(&1, "/sessions"))
    refute Enum.any?(lines, &String.contains?(&1, "/preflight"))
    refute Enum.any?(lines, &String.contains?(&1, "Work state"))
    refute Enum.any?(lines, &String.contains?(&1, "Useful commands"))
  end

  test "keeps screen unchanged when there is no activity and no hint" do
    screen = Screen.new(40, 6)

    assert RendererTranscript.draw(screen, 40, 1, 4, [], false, 0) == screen
  end

  test "draws transcript rows with rails and body indentation" do
    lines =
      Screen.new(50, 8)
      |> RendererTranscript.draw(50, 1, 6, ["you> hello", "ourocode> hi"], true, 0)
      |> Screen.to_lines()

    assert Enum.any?(lines, &String.contains?(&1, "Answer"))
    assert Enum.any?(lines, &String.contains?(&1, "│ hello"))
    assert Enum.any?(lines, &String.contains?(&1, "OUROCODE"))
    assert Enum.any?(lines, &String.contains?(&1, "│ hi"))
  end

  test "draws cancellation as a status row, not a bullet log" do
    text =
      Screen.new(60, 6)
      |> RendererTranscript.draw(60, 0, 5, ["Interview cancelled."], true, 0)
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "│ Interview cancelled."
    refute text =~ "• Interview cancelled."
  end

  test "scrolls back from the transcript tail" do
    activity = Enum.map(1..8, &"> line #{&1}")

    tail =
      Screen.new(40, 5)
      |> RendererTranscript.draw(40, 0, 4, activity, true, 0)
      |> Screen.to_lines()
      |> Enum.join("\n")

    scrolled =
      Screen.new(40, 5)
      |> RendererTranscript.draw(40, 0, 4, activity, true, 2)
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert tail =~ "line 8"
    refute tail =~ "line 3"
    assert scrolled =~ "line 6"
    refute scrolled =~ "line 8"
  end

  test "workspace activity renders from the top instead of the transcript tail" do
    activity =
      [
        "Resume",
        "resumable · 8 items",
        "Work"
      ] ++
        Enum.map(1..8, &"  #{if(&1 == 1, do: ">>", else: "  ")} Saved workspace #{&1}") ++
        [
          "Focus",
          "  Saved workspace 1 · resumable",
          "Try /resume latest | /resume 1",
          "Move with Up/Dn rows; Enter resume; type to compose"
        ]

    text =
      Screen.new(80, 8)
      |> RendererTranscript.draw(80, 0, 7, activity, true, 0)
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "Resume"
    assert text =~ "resumable"
    assert text =~ "Work"
    refute text =~ "Run:"
  end

  test "does nothing when the target region has no room" do
    screen = Screen.new(20, 4)

    assert RendererTranscript.draw(screen, 20, 3, 2, ["you> hidden"], true, 0, nil) == screen
  end
end
