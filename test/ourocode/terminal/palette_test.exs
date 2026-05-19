defmodule Ourocode.Terminal.PaletteTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Palette

  test "entries are sourced from the merged builtin registry" do
    slashes = Palette.entries() |> Enum.map(& &1.slash)

    assert "/help" in slashes
    assert "/status" in slashes
    assert "/mcp" in slashes
    assert "/sessions" in slashes
    assert "/config" in slashes
    assert Enum.all?(Palette.entries(), &is_binary(&1.summary))
  end

  test "filter with empty or bare slash returns all" do
    all = Palette.entries()
    assert Palette.filter(all, "") == all
    assert Palette.filter(all, "/") == all
  end

  test "filter matches slash and name case-insensitively with fuzzy ranking" do
    all = Palette.entries()
    result = Palette.filter(all, "/ST")

    assert Enum.any?(result, &(&1.slash == "/status"))
    refute Enum.any?(result, &(&1.slash == "/help"))
    assert hd(result).slash == "/status"
  end

  test "filter returns empty for no match" do
    assert Palette.filter(Palette.entries(), "/zzzznope") == []
  end

  test "clamp wraps around bounds" do
    assert Palette.clamp(0, 0) == 0
    assert Palette.clamp(-1, 3) == 2
    assert Palette.clamp(3, 3) == 0
    assert Palette.clamp(1, 3) == 1
  end

  test "selected returns the wrapped entry or nil" do
    assert Palette.selected([], 0) == nil
    entries = Palette.entries()
    first = Palette.selected(entries, 0)
    assert first == hd(entries)
    assert Palette.selected(entries, length(entries)) == hd(entries)
  end
end
