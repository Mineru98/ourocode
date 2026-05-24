defmodule Ourocode.Terminal.RendererChromeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererChrome, Screen}

  test "draw_composer uses prompt text and highlights ooo token through rendered text" do
    lines =
      60
      |> Screen.new(8)
      |> RendererChrome.draw_composer(60, 4, "ooo interview", :normal, %{})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "> ooo interview"
    refute text =~ "Message ourocode"
  end

  test "draw_status_bar surfaces notification over default hints" do
    sections = %{}
    kv = %{"runtime" => "ready", "transports" => "stdio,sse,streamable_http"}

    lines =
      80
      |> Screen.new(4)
      |> RendererChrome.draw_status_bar(80, 3, kv, sections, :normal, %{
        notifications: ["Esc again to clear input"]
      })
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "ready   stdio sse http"
    assert text =~ "Esc again to clear input"
    refute text =~ "^C  exit"
  end
end
