defmodule Ourocode.Terminal.RendererTranscriptTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererTranscript, Screen}

  test "draws centered empty-state hint when requested" do
    lines =
      Screen.new(60, 10)
      |> RendererTranscript.draw(60, 1, 8, [], true, 0)
      |> Screen.to_lines()

    assert Enum.any?(lines, &String.contains?(&1, "ourocode"))
    assert Enum.any?(lines, &String.contains?(&1, "Sign in with  /login"))
    assert Enum.any?(lines, &String.contains?(&1, "or type  /  to browse commands"))
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

    assert Enum.any?(lines, &String.contains?(&1, "YOU"))
    assert Enum.any?(lines, &String.contains?(&1, "| hello"))
    assert Enum.any?(lines, &String.contains?(&1, "OUROCODE"))
    assert Enum.any?(lines, &String.contains?(&1, "| hi"))
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

  test "does nothing when the target region has no room" do
    screen = Screen.new(20, 4)

    assert RendererTranscript.draw(screen, 20, 3, 2, ["you> hidden"], true, 0, nil) == screen
  end
end
