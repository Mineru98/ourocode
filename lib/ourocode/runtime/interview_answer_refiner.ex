defmodule Ourocode.Runtime.InterviewAnswerRefiner do
  @moduledoc """
  Structures user interview answers before they are forwarded to MCP.
  """

  alias Ourocode.Runtime.InterviewResponse

  @refine_options [
    %{
      label: "Send as-is",
      description: "The structure captures my answer faithfully"
    },
    %{
      label: "Add to Constraints",
      description: "I want to add a constraint I forgot"
    },
    %{
      label: "Add to Out of scope",
      description: "I want to mark something explicitly out of scope"
    },
    %{
      label: "Rewrite",
      description: "Let me re-state the answer"
    }
  ]

  @spec needs_refine?(String.t()) :: boolean()
  def needs_refine?(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> false
      String.starts_with?(trimmed, "[from-") -> false
      short_answer?(trimmed) -> false
      true -> carries_structure?(trimmed)
    end
  end

  def needs_refine?(_text), do: false

  @spec payload(String.t(), keyword()) :: String.t()
  def payload(answer, opts \\ []) when is_binary(answer) do
    answer = clean(answer)
    question = opts |> Keyword.get(:question, "") |> clean()

    [
      "[from-user][refined]",
      "Decision: #{sentence(answer)}",
      "",
      "Reasoning:",
      "- User stated: #{answer}",
      "",
      "Constraints (user-stated):",
      "- Not specified.",
      "",
      "Out of scope (user-stated):",
      "- Not specified.",
      codebase_context(question)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  @spec refine_question(String.t()) :: String.t()
  def refine_question(payload) when is_binary(payload) do
    """
    I structured your answer before sending it to MCP:

    #{payload}

    Is anything missing or misrepresented?
    """
    |> String.trim()
  end

  @spec refine_options() :: [map()]
  def refine_options, do: @refine_options

  @spec apply_refine_choice(String.t(), String.t(), String.t()) ::
          {:send, String.t()} | {:collect_more, String.t()}
  def apply_refine_choice(payload, choice, original_answer)
      when is_binary(payload) and is_binary(choice) do
    normalized = normalize_choice(choice)

    cond do
      normalized == "send as-is" ->
        {:send, payload}

      normalized in ["add to constraints", "add to out of scope", "rewrite"] ->
        {:collect_more, missing_text_question(payload)}

      String.trim(choice) != "" ->
        {:send, payload(original_answer <> "\n" <> choice)}

      true ->
        {:send, payload}
    end
  end

  defp short_answer?(text) do
    word_count(text) <= 3 and not String.contains?(text, ["\n", ".", ";", " because ", " so "])
  end

  defp carries_structure?(text) do
    word_count(text) >= 8 or
      String.contains?(String.downcase(text), [
        "\n",
        ".",
        ";",
        " because ",
        " constraint",
        " scope",
        " out of scope",
        "reason",
        "해야",
        "범위",
        "제약"
      ])
  end

  defp missing_text_question(payload) do
    """
    What text should I add or change before sending this to MCP?

    Current structured answer:

    #{payload}
    """
    |> String.trim()
  end

  defp codebase_context(""), do: nil

  defp codebase_context(question) do
    """

    Codebase context (main session verified):
    - No additional code context was attached for this user-judgment answer.
    - MCP question: #{question}
    """
    |> String.trim_trailing()
  end

  defp normalize_choice(choice) do
    choice
    |> String.trim()
    |> String.downcase()
  end

  defp clean(text) do
    text
    |> InterviewResponse.clean_markdown()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp sentence(text) do
    if String.ends_with?(text, [".", "!", "?"]), do: text, else: text <> "."
  end

  defp word_count(text) do
    text
    |> String.split(~r/\s+/u, trim: true)
    |> length()
  end
end
