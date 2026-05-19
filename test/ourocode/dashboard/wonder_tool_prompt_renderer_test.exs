defmodule Ourocode.Dashboard.WonderToolPromptRendererTest do
  use ExUnit.Case, async: true

  alias Ourocode.Dashboard.WonderToolPromptRenderer

  test "renders decision multiple-choice options with stable numbering" do
    prompt =
      render_prompt(:decision,
        request_id: "decision-1",
        header: "Decision",
        id: "route_choice",
        question: "Which runtime should handle this task?",
        options: [
          option("Ouroboros (Recommended)", "Route through Ouroboros workflow execution."),
          option("OpenCode", "Open a read-only OpenCode child session.")
        ]
      )

    assert %{
             id: :wonder_tool,
             kind: :wonder_tool_multiple_choice_prompt,
             title: "wonderTool",
             request_id: "decision-1",
             question_count: 1,
             questions: [
               %{
                 id: "route_choice",
                 kind: "decision",
                 header: "Decision",
                 question: "Which runtime should handle this task?",
                 options: [
                   %{
                     index: 1,
                     marker: "1.",
                     label: "Ouroboros (Recommended)",
                     recommended?: true,
                     line:
                       "  1. Ouroboros (Recommended) - Route through Ouroboros workflow execution."
                   },
                   %{
                     index: 2,
                     marker: "2.",
                     label: "OpenCode",
                     recommended?: false,
                     line: "  2. OpenCode - Open a read-only OpenCode child session."
                   }
                 ],
                 lines: [
                   "[decision] Decision: Which runtime should handle this task?",
                   "  1. Ouroboros (Recommended) - Route through Ouroboros workflow execution.",
                   "  2. OpenCode - Open a read-only OpenCode child session."
                 ]
               }
             ],
             lines: [
               "[decision] Decision: Which runtime should handle this task?",
               "  1. Ouroboros (Recommended) - Route through Ouroboros workflow execution.",
               "  2. OpenCode - Open a read-only OpenCode child session."
             ]
           } = prompt
  end

  test "renders permission prompt option lists with the same row format" do
    prompt =
      render_prompt(:permission,
        request_id: "permission-1",
        header: "Permission",
        id: "allow_scan",
        question: "Allow ourocode to inspect process metadata for cleanup?",
        options: [
          option("Allow (Recommended)", "Records process IDs in the local journal."),
          option("Deny", "Skips process metadata collection.")
        ]
      )

    assert [question] = prompt.questions
    assert question.kind == "permission"
    assert Enum.map(question.options, & &1.marker) == ["1.", "2."]

    assert question.lines == [
             "[permission] Permission: Allow ourocode to inspect process metadata for cleanup?",
             "  1. Allow (Recommended) - Records process IDs in the local journal.",
             "  2. Deny - Skips process metadata collection."
           ]
  end

  test "renders clarification prompt option lists with the same row format" do
    prompt =
      render_prompt(:clarification,
        request_id: "clarify-1",
        header: "Clarify",
        id: "target_scope",
        question: "Which source should be inspected first?",
        options: [
          option("Ouroboros (Recommended)", "Inspect sessions and jobs first."),
          option("OpenCode", "Inspect childID pane mappings first."),
          option("Codex", "Inspect native session and thread IDs first.")
        ]
      )

    assert [question] = prompt.questions
    assert question.kind == "clarification"
    assert Enum.map(question.options, & &1.marker) == ["1.", "2.", "3."]

    assert question.lines == [
             "[clarification] Clarify: Which source should be inspected first?",
             "  1. Ouroboros (Recommended) - Inspect sessions and jobs first.",
             "  2. OpenCode - Inspect childID pane mappings first.",
             "  3. Codex - Inspect native session and thread IDs first."
           ]
  end

  test "renders terminal-safe preview placeholders without embedding rich media" do
    prompt =
      render_prompt(:decision,
        request_id: "decision-preview-1",
        header: "Preview",
        id: "asset_choice",
        question: "Which asset should be used?",
        options: [
          %{
            label: "Image",
            description: "Use the uploaded image.",
            previewPlaceholder: "[Image #1]",
            preview: "uploaded screenshot"
          },
          option("Other", "Type a different asset.")
        ]
      )

    assert [question] = prompt.questions
    assert [%{line: image_line}, _other] = question.options

    assert image_line ==
             "  1. Image - Use the uploaded image. [preview: uploaded screenshot, [Image #1]]"

    assert image_line =~ "[Image #1]"
  end

  test "formats rendered prompt data as terminal lines" do
    prompt =
      render_prompt(:decision,
        request_id: "decision-line-1",
        header: "Decision",
        id: "strategy",
        question: "Which renderer strategy should stay active?",
        options: [
          option("Current (Recommended)", "Keep the active renderer."),
          option("Rollback", "Restore the previous renderer.")
        ]
      )

    assert WonderToolPromptRenderer.render_lines(prompt) == prompt.lines

    assert WonderToolPromptRenderer.render_line(prompt) ==
             Enum.join(prompt.lines, "\n")
  end

  defp render_prompt(kind, attrs) do
    payload = %{
      tool: "wonderTool",
      request_id: Keyword.fetch!(attrs, :request_id),
      interaction_kind: Atom.to_string(kind),
      questions: [
        %{
          id: Keyword.fetch!(attrs, :id),
          header: Keyword.fetch!(attrs, :header),
          question: Keyword.fetch!(attrs, :question),
          options: Keyword.fetch!(attrs, :options)
        }
      ]
    }

    WonderToolPromptRenderer.render(payload)
  end

  defp option(label, description) do
    %{
      label: label,
      description: description
    }
  end
end
