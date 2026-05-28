defmodule Ourocode.Terminal.RendererOverlayTest do
  use ExUnit.Case, async: true

  alias Ourocode.Model
  alias Ourocode.Terminal.{RendererOverlay, Screen}

  test "draw_palette renders selected command rows and detail above the overlay" do
    entries = [
      entry("/run", "Run a seed"),
      entry("/status", "Show status", :stub)
    ]

    screen =
      Screen.new(80, 16)
      |> RendererOverlay.draw_palette(80, 14, %{entries: entries, index: 1})

    lines = Screen.to_lines(screen)

    text = Enum.join(lines, "\n")

    assert text =~ "commands  (2)"
    assert text =~ "  /run         Run a seed"
    assert text =~ "● > /status      Show status  (stub)"
    assert text =~ "● /status"
    assert text =~ "Purpose · Show status"
    assert text =~ "Preview only"
    refute text =~ "source="
    refute text =~ "capability"
    assert row_styles(screen, "Purpose · Show status") == [:p_muted]
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

    assert text =~ "model"
    assert text =~ "Codex                ready"
    assert text =~ "● > Claude               sign in required"
  end

  test "draw_ooo_suggestions windows long lists around the selected row" do
    suggestions = for i <- 1..12, do: {"ooo cmd#{i}", "summary #{i}"}

    lines =
      Screen.new(72, 16)
      |> RendererOverlay.draw_ooo_suggestions(72, 14, suggestions, 10)
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    refute text =~ "ooo cmd1           summary 1"
    assert text =~ "ooo structured work"
    assert text =~ "ooo cmd4"
    assert text =~ "● > ooo cmd11"
    assert text =~ "ooo cmd10"
  end

  test "draw_ooo_suggestions keeps the workflow overlay anchored while filtering" do
    one_match = [{"ooo interview", "clarify requirements through a Socratic interview"}]
    many_matches = for i <- 1..8, do: {"ooo cmd#{i}", "summary #{i}"}

    one_lines =
      Screen.new(72, 18)
      |> RendererOverlay.draw_ooo_suggestions(72, 16, one_match, 0)
      |> Screen.to_lines()

    many_lines =
      Screen.new(72, 18)
      |> RendererOverlay.draw_ooo_suggestions(72, 16, many_matches, 0)
      |> Screen.to_lines()

    assert row_index(one_lines, "ooo structured work") ==
             row_index(many_lines, "ooo structured work")

    assert row_index(one_lines, "● ooo interview") ==
             row_index(many_lines, "● ooo cmd1")
  end

  test "draw_ooo_suggestions integrates selected command detail into the filled panel" do
    suggestions = [{"ooo pm", "shape product requirements through a PM interview"}]

    text =
      Screen.new(80, 18)
      |> RendererOverlay.draw_ooo_suggestions(80, 16, suggestions, 0)
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "ooo structured work"
    assert text =~ "● ooo pm · shape product requirements"
    assert text =~ "Enter inserts command; add context before running"
    assert text =~ "Try · ooo pm <context>"
    assert text =~ "● > ooo pm"
    refute text =~ "selected ooo pm"
    refute text =~ "example ooo pm"
    refute text =~ "about shape"
  end

  test "draw_ooo_suggestions uses compact workflow copy on narrow terminals" do
    suggestions = [{"ooo pm", "shape product requirements through a PM interview"}]

    text =
      Screen.new(60, 18)
      |> RendererOverlay.draw_ooo_suggestions(60, 16, suggestions, 0)
      |> Screen.to_lines()
      |> Enum.join("\n")

    assert text =~ "ooo workflows"
    assert text =~ "● ooo pm · PM interview"
    assert text =~ "Enter inserts it; add context"
    assert text =~ "● > ooo pm"
    assert text =~ "PM interview"
    refute text =~ "through a PM int"
    refute text =~ "shape product..."
  end

  test "draw_key_help switches help rows for paused interview mode" do
    lines =
      Screen.new(72, 12)
      |> RendererOverlay.draw_key_help(72, 10, :normal, %{interview_paused: true})
      |> Screen.to_lines()

    text = Enum.join(lines, "\n")

    assert text =~ "keys"
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

  defp row_index(lines, text), do: Enum.find_index(lines, &String.contains?(&1, text))

  defp row_styles(%{rows: rows}, text) do
    rows
    |> Enum.find_value([], fn {_y, row} ->
      plain =
        row
        |> Enum.sort_by(fn {x, _cell} -> x end)
        |> Enum.map(fn
          {_x, {:cont, _style}} -> ""
          {_x, {grapheme, _style}} -> grapheme
        end)
        |> Enum.join()

      if String.contains?(plain, text) do
        row
        |> Enum.map(&cell_style/1)
        |> Enum.uniq()
      end
    end)
  end

  defp cell_style({_x, {:cont, style}}), do: style
  defp cell_style({_x, {text, style}}) when is_binary(text), do: style
end
