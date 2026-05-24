defmodule Ourocode.Terminal.HistoryNavigationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.HistoryNavigation

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        buffer: "",
        cursor: 0,
        history: ["ooo seed", "ooo interview"],
        history_index: 0,
        history_draft: nil,
        ooo_cache: :cached,
        ooo_cache_loaded_ms: 123
      },
      overrides
    )
  end

  test "remember prepends unique entries and resets navigation state" do
    remembered =
      HistoryNavigation.remember(state(%{history_index: 1, history_draft: "draft"}), "ooo run", 3)

    assert remembered.history == ["ooo run", "ooo seed", "ooo interview"]
    assert remembered.history_index == 0
    assert remembered.history_draft == nil
    assert remembered.ooo_cache == nil
    assert remembered.ooo_cache_loaded_ms == nil
  end

  test "remember does not duplicate the newest history entry" do
    remembered = HistoryNavigation.remember(state(), "ooo seed", 3)
    assert remembered.history == ["ooo seed", "ooo interview"]
  end

  test "move up walks newest-first history and preserves the draft" do
    first = HistoryNavigation.move(state(%{buffer: "current draft", cursor: 13}), -1)
    assert first.buffer == "ooo seed"
    assert first.cursor == String.length("ooo seed")
    assert first.history_index == 1
    assert first.history_draft == "current draft"

    second = HistoryNavigation.move(first, -1)
    assert second.buffer == "ooo interview"
    assert second.history_index == 2
    assert second.history_draft == "current draft"
  end

  test "move down returns through history to the original draft" do
    at_oldest =
      state(%{
        buffer: "ooo interview",
        cursor: String.length("ooo interview"),
        history_index: 2,
        history_draft: "current draft"
      })

    newer = HistoryNavigation.move(at_oldest, 1)
    assert newer.buffer == "ooo seed"
    assert newer.history_index == 1

    draft = HistoryNavigation.move(newer, 1)
    assert draft.buffer == "current draft"
    assert draft.cursor == String.length("current draft")
    assert draft.history_index == 0
    assert draft.history_draft == nil
  end

  test "reset clears only the history cursor" do
    reset =
      HistoryNavigation.reset(state(%{buffer: "keep", history_index: 1, history_draft: "draft"}))

    assert reset.buffer == "keep"
    assert reset.history_index == 0
    assert reset.history_draft == nil
  end
end
