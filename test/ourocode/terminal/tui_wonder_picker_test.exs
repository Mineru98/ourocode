defmodule Ourocode.Terminal.TuiWonderPickerTest do
  @moduledoc """
  The wonderTool checkpoint renders as a real picker: one question at a time
  with a moving ">>" cursor, a "Question i/n" header only when multi, and Tab
  navigation across questions. These assert the deterministic view contract
  (`Tui.wonder_picker_lines/2`) independent of the raw terminal.
  """

  use ExUnit.Case, async: true

  alias Ourocode.Terminal.Tui

  defp detection(questions) do
    %{request: %{tool: :wonder_tool, type: :multiple_choice_decision, questions: questions}}
  end

  defp opt(label, desc, recommended? \\ false) do
    %{label: label, description: desc, recommended?: recommended?}
  end

  test "single question: no i/n header, cursor on the picked option" do
    det =
      detection([
        %{
          id: "transport",
          header: "Transport",
          question: "Which transport should the interview prioritize?",
          options: [opt("stdio", "local pipe"), opt("http", "remote stream")]
        }
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 0}})

    assert Enum.at(lines, 0) == "Transport"
    assert Enum.at(lines, 1) == "Which transport should the interview prioritize?"
    assert Enum.at(lines, 2) == ">> [1] stdio - local pipe"
    assert Enum.at(lines, 3) == "   [2] http - remote stream"
    assert Enum.at(lines, 4) == "   [Free answer] type below, then Enter"
  end

  test "string-keyed detection requests render the same picker" do
    det = %{
      "request_id" => "wt-string",
      request: %{
        "questions" => [
          %{
            "id" => "scope",
            "header" => "Scope",
            "question" => "Which scope should we take?",
            "options" => [
              %{"label" => "small", "description" => "one module"},
              %{"label" => "broad", "description" => "whole app"}
            ]
          }
        ]
      }
    }

    lines = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 1}})

    assert "Scope" in lines
    assert "Which scope should we take?" in lines
    assert ">> [2] broad - whole app" in lines
  end

  test "markdown emphasis is rendered as terminal text, not raw markers" do
    det =
      detection([
        %{
          id: "ux",
          header: "**Interview**",
          question: "현재 UX에서 가장 **답답하거나 거슬리는** 순간이 어떤 건가요?",
          options: [
            opt("**Interview flow**", "질문 상태가 `어디서` 일어나는지 추적하기 어렵다"),
            opt("TUI", "시각적으로 안 맞는다")
          ]
        }
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 0}})

    assert Enum.at(lines, 0) == "Interview"
    assert Enum.at(lines, 1) == "현재 UX에서 가장 답답하거나 거슬리는 순간이 어떤 건가요?"
    assert Enum.at(lines, 2) == ">> [1] Interview flow - 질문 상태가 어디서 일어나는지 추적하기 어렵다"
    refute Enum.join(lines, "\n") =~ "**"
    refute Enum.join(lines, "\n") =~ "`"
  end

  test "unstable emoji glyphs are stripped from picker text" do
    det =
      detection([
        %{
          id: "ux",
          header: "Interview",
          question: "어떤 지점이 답답한가요? 🧭",
          options: [
            opt("인터뷰 플로우 🧭", "질문 답변 흐름이 끊긴다"),
            opt("정보 가시성 �", "화면에서 상태를 찾기 어렵다")
          ]
        }
      ])

    text = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 1}}) |> Enum.join("\n")

    assert text =~ "인터뷰 플로우 - 질문 답변 흐름이 끊긴다"
    assert text =~ ">> [2] 정보 가시성 - 화면에서 상태를 찾기 어렵다"
    refute text =~ "🧭"
    refute text =~ "�"
  end

  test "moving the cursor highlights a different option" do
    det =
      detection([
        %{
          id: "scope",
          header: "Scope",
          question: "How wide?",
          options: [
            opt("narrow", "one feature"),
            opt("mid", "a module"),
            opt("broad", "whole app")
          ]
        }
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 2}})

    assert "   [1] narrow - one feature" in lines
    assert "   [2] mid - a module" in lines
    assert ">> [3] broad - whole app" in lines
    assert "   [Free answer] type below, then Enter" in lines
  end

  test "free answer is a selectable row after the concrete options" do
    det =
      detection([
        %{
          id: "scope",
          header: "Scope",
          question: "How wide?",
          options: [opt("narrow", "one feature"), opt("broad", "whole app")]
        }
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 2}})

    assert "   [1] narrow - one feature" in lines
    assert "   [2] broad - whole app" in lines
    assert ">> [Free answer] type below, then Enter" in lines
  end

  test "up/down navigation can leave the free answer row" do
    det =
      detection([
        %{
          id: "scope",
          header: "Scope",
          question: "How wide?",
          options: [opt("narrow", "one feature"), opt("broad", "whole app")]
        }
      ])

    nav = %{qidx: 0, picks: %{0 => 2}}

    nav = Tui.wonder_nav_after(det, nav, %{key: :up})
    assert ">> [2] broad - whole app" in Tui.wonder_picker_lines(det, nav)

    nav = Tui.wonder_nav_after(det, nav, %{key: :down})
    assert ">> [Free answer] type below, then Enter" in Tui.wonder_picker_lines(det, nav)
  end

  test "single-select highlight follows picks even when multi-select cursors exist" do
    det =
      detection([
        %{
          id: "scope",
          header: "Scope",
          question: "How wide?",
          options: [
            opt("narrow", "one feature"),
            opt("mid", "a module"),
            opt("broad", "whole app")
          ]
        }
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 0, cursors: %{0 => 0}, picks: %{0 => 2}})

    assert "   [1] narrow - one feature" in lines
    assert ">> [3] broad - whole app" in lines
  end

  test "multi-select question shows checked options and a separate cursor" do
    det =
      detection([
        %{
          id: "axes",
          header: "Axes",
          question: "Which axes?",
          multi_select?: true,
          options: [
            opt("Users", "grow adoption"),
            opt("Features", "complete core scope"),
            opt("Business", "make it sustainable")
          ]
        }
      ])

    lines =
      Tui.wonder_picker_lines(det, %{
        qidx: 0,
        cursors: %{0 => 2},
        picks: %{0 => MapSet.new([0, 2])}
      })

    assert "   [x] [1] Users - grow adoption" in lines
    assert "   [ ] [2] Features - complete core scope" in lines
    assert ">> [x] [3] Business - make it sustainable" in lines
  end

  test "multi question: header shows i/n and Tab lands on the right question" do
    det =
      detection([
        %{
          id: "transport",
          header: "Transport",
          question: "Which transport?",
          options: [opt("stdio", "local"), opt("http", "remote")]
        },
        %{
          id: "scope",
          header: "Scope",
          question: "Which scope?",
          options: [opt("narrow", "one"), opt("broad", "all")]
        }
      ])

    q1 = Tui.wonder_picker_lines(det, %{qidx: 0, picks: %{0 => 0, 1 => 1}})
    assert Enum.at(q1, 0) == "Question 1/2  [*.]  ·  Transport"
    assert Enum.at(q1, 1) == "Which transport?"
    assert ">> [1] stdio - local" in q1

    # Tab advances qidx; the second question's remembered pick is shown.
    q2 = Tui.wonder_picker_lines(det, %{qidx: 1, picks: %{0 => 0, 1 => 1}})
    assert Enum.at(q2, 0) == "Question 2/2  [.*]  ·  Scope"
    assert Enum.at(q2, 1) == "Which scope?"
    assert "   [1] narrow - one" in q2
    assert ">> [2] broad - all" in q2
  end

  test "multi question review state summarizes picks before final submit" do
    det =
      detection([
        %{
          id: "transport",
          header: "Transport",
          question: "Which transport?",
          options: [opt("stdio", "local"), opt("http", "remote")]
        },
        %{
          id: "scope",
          header: "Scope",
          question: "Which scope?",
          options: [opt("narrow", "one"), opt("broad", "all")]
        }
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 1, picks: %{0 => 0, 1 => 1}, review?: true})

    assert Enum.at(lines, 0) == "Review answers before submit"
    assert Enum.at(lines, 1) == "Enter confirms all selections, Esc returns to main session"
    assert "[1/2] Transport" in lines
    assert "  stdio" in lines
    assert "[2/2] Scope" in lines
    assert "  broad" in lines
  end

  test "an out-of-range question index clamps instead of crashing" do
    det =
      detection([
        %{id: "only", header: "Only", question: "Pick", options: [opt("a", "x"), opt("b", "y")]}
      ])

    lines = Tui.wonder_picker_lines(det, %{qidx: 9, picks: %{}})
    assert Enum.at(lines, 0) == "Only"
    assert ">> [1] a - x" in lines
  end

  test "no questions renders nothing" do
    assert Tui.wonder_picker_lines(detection([]), nil) == []
    assert Tui.wonder_picker_lines(%{}, nil) == []
  end
end
