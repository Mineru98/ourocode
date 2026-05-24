defmodule Ourocode.WonderTool.OptionSelectionTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.OptionSelection

  test "normalizes one selection for single-select questions" do
    assert {:ok, [2]} = OptionSelection.normalize(question_fixture(), %{"selectedOption" => 2})
  end

  test "rejects multiple selections for single-select questions" do
    assert {:error, {:exactly_one_selection_required, 2}} =
             OptionSelection.normalize(question_fixture(), %{"selectedOptions" => [1, 2]})
  end

  test "allows multiple selections for multi-select questions" do
    question = Map.put(question_fixture(), :multi_select?, true)

    assert {:ok, [1, 2]} = OptionSelection.normalize(question, %{"selectedOptions" => [1, 2]})
  end

  test "infers an Other selection from free text" do
    assert {:ok, ["Other"]} =
             OptionSelection.normalize(question_fixture(), %{"otherText" => "write my own"})
  end

  test "resolves selections by index, numeric string, and label" do
    assert {:ok, [{2, %{label: "OpenCode"}}]} = OptionSelection.resolve(question_fixture(), [2])
    assert {:ok, [{2, %{label: "OpenCode"}}]} = OptionSelection.resolve(question_fixture(), ["2"])

    assert {:ok, [{1, %{label: "Ouroboros"}}]} =
             OptionSelection.resolve(question_fixture(), [" ouroboros "])
  end

  test "deduplicates repeated selections after resolution" do
    assert {:ok, [{1, %{label: "Ouroboros"}}]} =
             OptionSelection.resolve(question_fixture(), [1, "Ouroboros"])
  end

  test "falls back to Other for unknown free-text labels when Other exists" do
    assert {:ok, [{3, %{label: "Other"}}]} =
             OptionSelection.resolve(question_fixture(), ["a custom option"])
  end

  test "returns structured errors for invalid input" do
    assert {:error, :selection_required} = OptionSelection.normalize(question_fixture(), %{})
    assert {:error, :options_required} = OptionSelection.resolve(%{}, [1])

    assert {:error, {:unknown_selected_option, 4}} =
             OptionSelection.resolve(question_fixture(), [4])
  end

  defp question_fixture do
    %{
      id: "route",
      options: [
        %{label: "Ouroboros"},
        %{label: "OpenCode"},
        %{label: "Other", other?: true}
      ]
    }
  end
end
