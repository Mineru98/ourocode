defmodule Ourocode.Terminal.InterviewPanel.WonderPickerTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.InterviewPanel.WonderPicker

  test "default_nav preserves navigation for the same request and initializes recommended picks" do
    detection =
      detection("req-1", [
        %{
          header: "Scope",
          options: [option("Small", false), option("Broad", true)]
        },
        %{
          header: "Checks",
          multi_select?: true,
          options: [option("Tests", true), option("Review", false)]
        }
      ])

    current = %{req_id: "req-1", qidx: 1, picks: %{0 => 0}}
    assert WonderPicker.default_nav(detection, current) == current

    assert WonderPicker.default_nav(detection, %{req_id: "old"}) == %{
             req_id: "req-1",
             qidx: 0,
             cursors: %{1 => 0},
             picks: %{0 => 1, 1 => MapSet.new([0])}
           }
  end

  test "lines renders review mode with multi-select labels" do
    detection =
      detection("req-1", [
        %{
          header: "Scope",
          options: [option("Small", false), option("Broad", false)]
        },
        %{
          header: "Checks",
          multi_select?: true,
          options: [option("Tests", false), option("Review", false)]
        }
      ])

    lines =
      WonderPicker.lines(detection, %{
        review?: true,
        picks: %{0 => 1, 1 => MapSet.new([0, 1])}
      })

    assert lines == [
             "Review answers before submit",
             "Enter confirms all selections, Esc pauses to discuss",
             "[1/2] Scope",
             "  Broad",
             "[2/2] Checks",
             "  Tests, Review"
           ]
  end

  test "lines renders picker cursor, markdown-cleaned copy, and free-answer row" do
    detection =
      detection("req-1", [
        %{
          header: "**Scope**",
          question: "Choose `one`",
          options: [
            %{label: "**Small**", description: "one module"},
            %{label: "Broad", description: "[whole app](https://example.com)"}
          ]
        }
      ])

    assert WonderPicker.lines(detection, %{qidx: 0, picks: %{0 => 1}}) == [
             "Scope",
             "Choose one",
             "   [1] Small - one module",
             ">> [2] Broad - whole app",
             "   [Custom answer] type any text, then Enter"
           ]
  end

  test "nav helpers normalize missing and integer multi-select picks" do
    assert WonderPicker.nav_qidx(%{qidx: 2}) == 2
    assert WonderPicker.nav_qidx(nil) == 0
    assert WonderPicker.nav_cursor(%{cursors: %{1 => 3}}, 1) == 3
    assert WonderPicker.nav_cursor(%{picks: %{1 => 2}}, 1) == 2
    assert WonderPicker.nav_pick(nil, 1) == 0
    assert WonderPicker.nav_multi_pick(%{picks: %{1 => 2}}, 1) == MapSet.new([2])

    assert WonderPicker.nav_multi_pick(%{picks: %{1 => MapSet.new([0, 2])}}, 1) ==
             MapSet.new([0, 2])
  end

  defp detection(request_id, questions) do
    %{request_id: request_id, request: %{questions: questions}}
  end

  defp option(label, recommended?) do
    %{label: label, description: "", recommended?: recommended?}
  end
end
