defmodule Ourocode.Terminal.RendererOverlayTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Terminal.{RendererOverlay, Screen}

  test "draw_palette renders selected command rows and detail above the overlay" do
    entries = [
      entry("/run", "Run a seed"),
      entry("/status", "Show status", :stub)
    ]

    lines =
      Screen.new(80, 16)
      |> RendererOverlay.draw_palette(80, 14, %{entries: entries, index: 1})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "+- commands  (2)"
    assert text =~ "  /run         Run a seed"
    assert text =~ "> /status      Show status  (stub)"
    assert text =~ "source=runtime"
  end

  test "draw_model distinguishes ready and auth-needed models" do
    models = [
      model(:codex, "Codex", :ready),
      model(:claude, "Claude", {:needs_auth, "/login"})
    ]

    lines =
      Screen.new(70, 12)
      |> RendererOverlay.draw_model(70, 10, %{models: models, index: 1})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "+- model"
    assert text =~ "Codex                ready"
    assert text =~ "> Claude               sign in required"
  end

  test "draw_ooo_suggestions windows long lists around the selected row" do
    suggestions = for i <- 1..12, do: {"ooo cmd#{i}", "summary #{i}"}

    lines =
      Screen.new(72, 16)
      |> RendererOverlay.draw_ooo_suggestions(72, 14, suggestions, 10)
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    refute text =~ "ooo cmd1           summary 1"
    assert text =~ "ooo cmd4"
    assert text =~ "> ooo cmd11"
    assert text =~ "ooo cmd10"
  end

  test "draw_key_help switches help rows for paused interview mode" do
    lines =
      Screen.new(72, 12)
      |> RendererOverlay.draw_key_help(72, 10, :normal, %{interview_paused: true})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "+- keys"
    assert text =~ "/answer <text>"
    assert text =~ "submit to interview"
    assert text =~ "type normally"
  end

  defp entry(slash, summary, availability \\ :ready) do
    %{
      slash: slash,
      name: String.trim_leading(slash, "/"),
      summary: summary,
      category: :test,
      source: :runtime,
      availability: availability,
      aliases: [],
      args: []
    }
  end

  defp model(id, label, status) do
    %Model{id: id, label: label, kind: :cli, status: status, run: fn _, _, _ -> {:ok, ""} end}
  end
end
