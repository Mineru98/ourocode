defmodule Ourocode.WonderTool.DecisionRequest.OptionsTest do
  use ExUnit.Case, async: true

  alias Ourocode.WonderTool.DecisionRequest.Options

  test "normalizes map options with recommendation, other, and preview fields" do
    assert {:ok, [first, second]} =
             Options.normalize(
               {:options,
                [
                  %{
                    "label" => "Allow (Recommended)",
                    "description" => "Continue.",
                    "previewPlaceholder" => "[Preview]",
                    "preview_placeholders" => [" first ", "", 42, "second"]
                  },
                  %{
                    label: "Other",
                    description: "Type another answer.",
                    allow_free_text: true
                  }
                ]}
             )

    assert first.recommended? == true
    assert first.preview_placeholder == "[Preview]"
    assert first.preview_placeholders == ["first", "second"]
    assert second.other? == true
  end

  test "allows string options only for choices shorthand" do
    assert {:ok, [%{label: "A", description: "A"}, %{label: "B", description: "B"}]} =
             Options.normalize({:choices, ["A", "B"]})

    assert {:error, {:invalid_option, 0, :option_must_be_map}} =
             Options.normalize({:options, ["A", "B"]})
  end

  test "validates option count and shape" do
    assert {:error, :at_least_two_options_required} = Options.normalize({:options, [%{}]})

    assert {:error, :at_most_four_options_allowed} =
             Options.normalize({:options, Enum.map(1..5, &%{label: "#{&1}", description: "x"})})

    assert {:error, {:invalid_option, 1, :description_required}} =
             Options.normalize({:options, [%{label: "A", description: "Alpha"}, %{label: "B"}]})

    assert {:error, :options_must_be_list} = Options.normalize({:options, %{}})
  end
end
