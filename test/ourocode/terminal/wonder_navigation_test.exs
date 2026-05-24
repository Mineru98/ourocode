defmodule Ourocode.Terminal.WonderNavigationTest do
  use ExUnit.Case, async: true

  alias Ourocode.Terminal.WonderNavigation

  test "moves single-select cursor through options and free answer row" do
    det =
      detection([
        %{
          id: "scope",
          header: "Scope",
          question: "How wide?",
          options: [opt("narrow"), opt("broad")]
        }
      ])

    nav = %{qidx: 0, picks: %{0 => 0}}

    assert WonderNavigation.after_event(det, nav, %{key: :down}) == %{qidx: 0, picks: %{0 => 1}}

    assert WonderNavigation.after_event(det, %{qidx: 0, picks: %{0 => 1}}, %{key: :down}) == %{
             qidx: 0,
             picks: %{0 => 2}
           }

    assert WonderNavigation.active_free_answer?(det, %{qidx: 0, picks: %{0 => 2}})
    refute WonderNavigation.nav_event?(%{key: :char, char: "1"}, "typed", det, nav)
    refute WonderNavigation.nav_event?(%{key: :right}, "", det, %{qidx: 0, picks: %{0 => 2}})
  end

  test "tabs across questions and computes one-based selections" do
    det =
      detection([
        %{id: "first", header: "First", question: "Pick one", options: [opt("a"), opt("b")]},
        %{id: "second", header: "Second", question: "Pick two", options: [opt("x"), opt("y")]}
      ])

    nav = %{qidx: 0, picks: %{0 => 1, 1 => 0}}

    assert WonderNavigation.after_event(det, nav, %{key: :tab}).qidx == 1
    assert WonderNavigation.selections(det, nav) == [2, 1]
  end

  test "toggles multi-select choices and reports selected free answer rows" do
    det =
      detection([
        %{
          id: "axes",
          header: "Axes",
          question: "Which axes?",
          multi_select?: true,
          options: [opt("Users"), opt("Features"), opt("Business")]
        }
      ])

    nav = %{qidx: 0, cursors: %{0 => 1}, picks: %{0 => MapSet.new([0])}}
    nav = WonderNavigation.after_event(det, nav, %{key: :char, char: " "})

    assert nav.picks[0] == MapSet.new([0, 1])
    assert WonderNavigation.selections(det, nav) == [[1, 2]]
    refute WonderNavigation.any_free_answer_selected?(det, nav)

    free_nav = %{nav | cursors: %{0 => 3}}
    assert WonderNavigation.any_free_answer_selected?(det, free_nav)
  end

  test "free text payload includes active question id when present" do
    det =
      detection([
        %{id: "first", header: "First", question: "Pick one", options: [opt("a")]},
        %{id: "second", header: "Second", question: "Explain", options: [opt("b")]}
      ])

    assert WonderNavigation.free_text_payload(det, %{qidx: 1, picks: %{1 => 1}}, "custom") == %{
             "freeText" => "custom",
             "questionId" => "second"
           }
  end

  defp detection(questions) do
    %{request: %{tool: :wonder_tool, type: :multiple_choice_decision, questions: questions}}
  end

  defp opt(label), do: %{label: label, description: "#{label} description"}
end
