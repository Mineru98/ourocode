defmodule Ourocode.Terminal.RendererChromeTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.{RendererChrome, Screen}

  test "spinner_frame cycles through the braille rotation" do
    assert RendererChrome.spinner_frame(0) == "⠋"
    assert RendererChrome.spinner_frame(1) == "⠙"
    assert RendererChrome.spinner_frame(10) == "⠋"
    assert Screen.text_width(RendererChrome.spinner_frame(3)) == 1
  end

  test "the thinking state shows the spinner instead of the status word's dot" do
    lines =
      90
      |> Screen.new(4)
      |> RendererChrome.draw_header(90, %{"status" => "healthy"}, %{streaming: true, tick: 2})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")
    assert text =~ "thinking"
    assert text =~ RendererChrome.spinner_frame(2)
  end

  test "draw_header uses product-facing subtitle" do
    lines =
      90
      |> Screen.new(4)
      |> RendererChrome.draw_header(90, %{"status" => "healthy"}, %{
        auth: {"model: codex  (ChatGPT)", :ok}
      })
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "plan, delegate, and verify from one terminal"
    refute text =~ "interactive baseline"
  end

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

  test "draw_composer uses richer entry placeholder on narrow terminals" do
    text =
      60
      |> Screen.new(8)
      |> RendererChrome.draw_composer(60, 4, "", :normal, %{})
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "[main]"
    assert text =~ "Ask, / command, or ooo auto/pm/run"
    refute text =~ "ooo starts structure"
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

    assert text =~ "Esc again to clear input"
    refute text =~ "^C  exit"
  end

  test "draw_meta_bar surfaces runtime metadata when the app is healthy" do
    lines =
      80
      |> Screen.new(4)
      |> RendererChrome.draw_meta_bar(
        80,
        3,
        %{"runtime" => "unknown", "status" => "healthy", "transports" => "none"},
        %{},
        :normal,
        %{}
      )
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "ready"
    assert text =~ "session"
    refute text =~ "offline"
  end

  test "draw_meta_bar uses local instead of offline for an active terminal without transports" do
    lines =
      80
      |> Screen.new(4)
      |> RendererChrome.draw_meta_bar(
        80,
        3,
        %{"runtime" => "?", "transports" => "none"},
        %{},
        :normal,
        %{}
      )
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "main"
    refute text =~ "?"
    refute text =~ "offline"
  end
end
