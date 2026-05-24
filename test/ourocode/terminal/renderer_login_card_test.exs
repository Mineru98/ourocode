defmodule Ourocode.Terminal.RendererLoginCardTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererLoginCard, Screen}

  test "draws the device login code url and approval hint" do
    text =
      Screen.new(80, 18)
      |> RendererLoginCard.draw(80, 4, 14, %{
        code: "ABCD-1234",
        url: "https://auth.openai.com/codex/device"
      })
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "Connect ChatGPT"
    assert text =~ "ABCD-1234"
    assert text =~ "https://auth.openai.com/codex/device"
    assert text =~ "waiting for approval - Ctrl-C to cancel"
  end

  test "uses stable fallback values for partial login state" do
    text =
      Screen.new(64, 16)
      |> RendererLoginCard.draw(64, 4, 12, %{})
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "Connect ChatGPT"
    assert text =~ "------"
    assert text =~ "waiting for approval"
  end
end
