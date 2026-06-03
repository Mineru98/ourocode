defmodule Ourocode.Runtime.InterviewOptionSynthesizer do
  @moduledoc """
  Builds durable suggested-answer options for interview checkpoints.

  Model-supplied options are preferred. When the router cannot provide them,
  this module derives concrete choices from the prompt text and finally falls
  back to decision-oriented defaults so the UI never has only free text.
  """

  alias Ourocode.Runtime.InterviewResponse

  @generic_ask_options [
    %{
      "label" => "Define the desired outcome",
      "description" => "Clarify what success should look like"
    },
    %{
      "label" => "Clarify the target user",
      "description" => "Start by naming who this is for"
    }
  ]

  @spec options([map()], term()) :: [map()]
  def options(model_options, prompt) do
    mapped =
      model_options
      |> model_options()
      |> Enum.take(4)
      |> Enum.map(&option/1)
      |> Enum.reject(&is_nil/1)

    {choices, source} =
      case mapped do
        [] -> {prompt_option_hints(prompt), :prompt}
        options -> {options, :model}
      end

    limit = option_limit(choices, source)

    choices
    |> append_fallback_options(prompt, source)
    |> Enum.uniq_by(& &1["label"])
    |> Enum.take(limit)
  end

  defp model_options(options) when is_list(options), do: options
  defp model_options(_options), do: []

  defp option(%{label: label, description: description}) do
    %{"label" => to_string(label), "description" => to_string(description)}
  end

  defp option(%{"label" => label, "description" => description}) do
    %{"label" => to_string(label), "description" => to_string(description)}
  end

  defp option(_option), do: nil

  defp append_fallback_options([], prompt, _source), do: fallback_options(prompt)
  defp append_fallback_options(options, prompt, :model), do: options ++ fallback_options(prompt)

  defp append_fallback_options(options, prompt, :prompt),
    do: options ++ generic_fill_options(prompt)

  defp option_limit([], _source), do: 4
  defp option_limit(choices, _source), do: max(2, length(choices))

  defp generic_fill_options(prompt) when is_binary(prompt) do
    prompt
    |> fallback_options()
    |> reject_mismatched_fillers(prompt)
  end

  defp generic_fill_options(_prompt), do: @generic_ask_options

  defp reject_mismatched_fillers(options, prompt) do
    prompt_words = content_words(prompt)

    Enum.filter(options, fn option ->
      label_words = content_words(option["label"])
      MapSet.size(MapSet.intersection(prompt_words, label_words)) > 0
    end)
  end

  defp fallback_options(prompt) when is_binary(prompt) do
    normalized = prompt |> InterviewResponse.clean_markdown() |> String.downcase()

    cond do
      String.contains?(normalized, ["smallest valid", "minimal", "minimum"]) and
          String.contains?(normalized, ["template", "structure", "scaffold"]) ->
        [
          %{
            "label" => "Generate the smallest valid structure",
            "description" => "Start from the minimal working plugin files"
          },
          %{
            "label" => "Guide template selection first",
            "description" => "Choose the right template before generating files"
          }
        ]

      String.contains?(normalized, ["email", "이메일"]) and
          String.contains?(normalized, ["gmail", "outlook", "imap", "mail"]) ->
        [
          %{
            "label" => "Connect Gmail first",
            "description" => "Prioritize the most common personal and workspace inbox"
          },
          %{
            "label" => "Connect Outlook first",
            "description" => "Prioritize Microsoft 365 and Exchange users"
          },
          %{
            "label" => "Connect Apple Mail/IMAP first",
            "description" => "Prioritize broad IMAP compatibility"
          },
          %{
            "label" => "Define importance criteria",
            "description" => "Clarify how important email should be detected"
          }
        ]

      korean_interview_flow_check?(normalized) ->
        [
          %{
            "label" => "질문이 다음 라운드로 이어진다",
            "description" => "답변 후 새 질문과 선택지가 자동으로 생성되는지 확인"
          },
          %{
            "label" => "답변이 다음 질문에 반영된다",
            "description" => "사용자 답변이 이후 질문의 맥락과 선택지에 남는지 확인"
          },
          %{
            "label" => "Seed 작성에 필요한 기준이 모인다",
            "description" => "인터뷰 결과가 요구사항/검증 기준으로 정리될 수 있는지 확인"
          }
        ]

      korean_success_criteria_question?(normalized) ->
        [
          %{
            "label" => "성공 기준을 먼저 정의",
            "description" => "잘 동작한다는 상태를 관찰 가능한 기준으로 고정"
          },
          %{
            "label" => "검증 방법을 먼저 정의",
            "description" => "어떤 테스트나 화면 확인으로 통과를 판단할지 고정"
          },
          %{
            "label" => "사용자 영향을 먼저 정의",
            "description" => "누가 어떤 문제 없이 사용할 수 있어야 하는지 고정"
          }
        ]

      String.contains?(normalized, ["template choice", "template selection", "which template"]) ->
        [
          %{
            "label" => "Pick the template first",
            "description" => "Start by selecting the right scaffold"
          },
          %{
            "label" => "Generate a minimal template",
            "description" => "Create the smallest useful starting point"
          }
        ]

      String.contains?(normalized, ["plugin structure", "plugin scaffold", "plugin files"]) ->
        [
          %{
            "label" => "Generate plugin structure",
            "description" => "Create the required files and manifest first"
          },
          %{
            "label" => "Clarify plugin behavior",
            "description" => "Define what the plugin should do before files"
          }
        ]

      String.contains?(normalized, ["core workflow", "core workflows"]) ->
        [
          %{
            "label" => "Guided work starts and advances",
            "description" => "Prove ooo opens an interview and accepts an answer"
          },
          %{
            "label" => "Plugin management views work",
            "description" => "Prove plugin, MCP, sandbox, and session views are usable"
          },
          %{
            "label" => "Verification passes cleanly",
            "description" => "Prove build and verify checks complete without failures"
          }
        ]

      String.contains?(normalized, ["readiness", "ready", "available"]) and
          String.contains?(normalized, ["mcp", "tool", "tools", "plugin"]) ->
        [
          %{
            "label" => "Plugin is loaded",
            "description" => "Confirm the plugin appears ready in the status surface"
          },
          %{
            "label" => "Tools are callable",
            "description" => "Confirm exposed tools can be inspected or invoked"
          }
        ]

      String.contains?(normalized, ["ux", "usable", "usability"]) ->
        [
          %{
            "label" => "Navigation feels direct",
            "description" => "Check keyboard movement and row actions"
          },
          %{
            "label" => "State is visible",
            "description" => "Check active work, pause, cancel, and next action cues"
          }
        ]

      String.contains?(normalized, ["onboarding", "onboarded", "activation"]) and
          String.contains?(normalized, [
            "audience",
            "user segment",
            "target user",
            "serve first",
            "primarily serve"
          ]) ->
        [
          %{
            "label" => "Existing agent users",
            "description" => "Optimize for users already working in coding terminals"
          },
          %{
            "label" => "First-time plugin installers",
            "description" => "Optimize for users proving plugin setup for the first time"
          },
          %{
            "label" => "Internal builders",
            "description" => "Optimize for maintainers validating the onboarding path"
          }
        ]

      String.contains?(normalized, ["onboarding", "onboarded", "activation"]) and
          String.contains?(normalized, ["completion signal", "prove", "proves", "worked"]) ->
        [
          %{
            "label" => "First guided run succeeds",
            "description" => "The user completes one ooo workflow without leaving the TUI"
          },
          %{
            "label" => "Plugin tools verify cleanly",
            "description" => "The user sees loaded tools and passes local verification"
          },
          %{
            "label" => "Next action is obvious",
            "description" => "The user knows the next command or decision to take"
          }
        ]

      String.contains?(normalized, ["onboarding", "onboarded", "activation"]) ->
        [
          %{
            "label" => "Define the target user",
            "description" => "Start with who the onboarding serves"
          },
          %{
            "label" => "Define the activation outcome",
            "description" => "Start with what success means"
          },
          %{
            "label" => "Audit the existing flow",
            "description" => "Start from current implementation gaps"
          }
        ]

      String.contains?(normalized, ["first", "priority", "focus"]) ->
        [
          %{
            "label" => "Clarify the first priority",
            "description" => "Choose the highest-impact decision first"
          },
          %{
            "label" => "Define the success criteria",
            "description" => "Start with how we will know it worked"
          }
        ]

      true ->
        @generic_ask_options
    end
  end

  defp fallback_options(_prompt), do: @generic_ask_options

  defp korean_interview_flow_check?(text) do
    korean?(text) and
      String.contains?(text, ["ooo interview", "인터뷰"]) and
      String.contains?(text, ["질문"]) and
      String.contains?(text, ["답변"]) and
      String.contains?(text, ["반영", "이어가", "이어지", "검증", "정상"])
  end

  defp korean_success_criteria_question?(text) do
    korean?(text) and
      String.contains?(text, ["기준", "성공", "검증", "잘 동작", "동작"]) and
      String.contains?(text, ["무엇", "어떤", "어떻게", "인가요", "원하시나요"])
  end

  defp korean?(text), do: Regex.match?(~r/[가-힣]/u, text)

  defp content_words(text) when is_binary(text) do
    text
    |> InterviewResponse.clean_markdown()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 4))
    |> Enum.reject(&(&1 in ["should", "would", "could", "first", "through", "around"]))
    |> MapSet.new()
  end

  defp content_words(_text), do: MapSet.new()

  defp prompt_option_hints(prompt) when is_binary(prompt) do
    candidates = option_candidate_text(prompt)
    source_text = InterviewResponse.clean_markdown(prompt)
    quoted = quoted_option_candidates(candidates)

    cond do
      quoted != [] ->
        quoted
        |> normalize_candidates()
        |> reject_fragmentary_choices()

      option_list_text?(candidates, source_text) ->
        candidates
        |> split_option_candidates()
        |> normalize_candidates()
        |> reject_fragmentary_choices()

      true ->
        []
    end
  end

  defp prompt_option_hints(_prompt), do: []

  defp option_candidate_text(prompt) do
    text = InterviewResponse.clean_markdown(prompt)

    case Regex.split(~r/[?？:：]/u, text, parts: 2) do
      [before, rest] ->
        rest = String.trim(rest)
        if rest == "", do: before, else: rest

      [only] ->
        only
    end
  end

  defp option_list_text?(text, source_text) do
    list_text = strip_parenthetical_spans(text)
    source_text = strip_parenthetical_spans(source_text)

    list_text =~ ~r/\b(?:or|versus|vs\.?)\b/iu or
      list_text =~ ~r/(?:아니면|또는|혹은)/u or
      (delimiter_count(list_text) >= 2 and
         explicit_choice_context?(list_text <> " " <> source_text))
  end

  defp delimiter_count(text) do
    Regex.scan(~r/[,，、]/u, text) |> length()
  end

  defp explicit_choice_context?(text) do
    String.contains?(text, ["중 하나", "무엇으로", "어디를", "선택", "삼을", "고정"]) or
      text =~ ~r/\b(?:choose|pick|select|which|what)\b/iu
  end

  defp quoted_option_candidates(text) do
    ~r/[“"]([^”"]{4,120})[”"]/u
    |> Regex.scan(text)
    |> Enum.map(fn [_match, candidate] -> candidate end)
    |> Enum.reject(&quoted_context_only?/1)
    |> Enum.uniq()
    |> then(fn candidates ->
      if length(candidates) >= 2, do: candidates, else: []
    end)
  end

  defp quoted_context_only?(candidate) do
    candidate = String.trim(candidate)
    String.length(candidate) < 4 or candidate in ["패턴", "성능 유지"]
  end

  defp trim_candidate(text) do
    Regex.replace(~r/\A[\s.!?;:]+|[\s.!?;:]+\z/u, text, "")
  end

  defp split_option_candidates(text) do
    text
    |> strip_parenthetical_spans()
    |> String.replace(~r/\b(?:or|versus|vs\.?)\b/iu, ",")
    |> String.replace(~r/\s*(?:아니면|또는|혹은)\s*/u, ",")
    |> String.split(~r/\s*[,，、]\s*/u)
  end

  defp strip_parenthetical_spans(text) do
    Regex.replace(~r/[\(\（][^\)\）]*[\)\）]/u, text, "")
  end

  defp normalize_candidates(candidates) when length(candidates) < 2, do: []

  defp normalize_candidates(candidates) do
    candidates
    |> Enum.with_index()
    |> Enum.map(fn {candidate, index} ->
      candidate
      |> String.trim()
      |> strip_leading_context()
      |> maybe_strip_question_prefix(index)
      |> strip_question_stem()
      |> maybe_strip_dependent_choice_prefix()
      |> strip_trailing_korean_choice_context()
      |> trim_candidate()
    end)
    |> Enum.reject(&(String.length(&1) < 2))
    |> Enum.reject(&context_only?/1)
    |> Enum.uniq()
    |> Enum.take(4)
    |> Enum.map(fn label ->
      %{"label" => label, "description" => label}
    end)
  end

  defp reject_fragmentary_choices([]), do: []

  defp reject_fragmentary_choices(options) do
    labels = Enum.map(options, &String.downcase(&1["label"]))

    if sentence_fragment_choices?(labels), do: [], else: options
  end

  defp sentence_fragment_choices?(labels) do
    Enum.any?(labels, &dependent_clause?/1) or
      (length(labels) >= 3 and Enum.count(labels, &single_action_word?/1) >= 2)
  end

  defp dependent_clause?(label) do
    String.starts_with?(label, ["that ", "when ", "if ", "and "])
  end

  defp maybe_strip_dependent_choice_prefix(candidate) do
    Regex.replace(~r/\A(?:that|whether)\s+/iu, candidate, "")
  end

  defp strip_leading_context(candidate) do
    candidate
    |> then(&Regex.replace(~r/\Afor\s+[^,]+,\s*/iu, &1, ""))
    |> then(&Regex.replace(~r/\A(?:예를\s*들어|예시(?:로)?|예컨대)\s*/u, &1, ""))
  end

  defp context_only?(candidate) do
    String.match?(candidate, ~r/\Afor\s+[^,?.:]+\z/iu)
  end

  defp strip_question_stem(candidate) do
    Regex.replace(~r/\Ashould\s+the\s+interview\s+clarify\s+/iu, candidate, "")
  end

  defp strip_trailing_korean_choice_context(candidate) do
    Regex.replace(
      ~r/\s*중\s+(?:하나|무엇|어디)(?:를)?(?:\s*선택하고.*|\s*삼고.*|\s*정할까요.*|.*)?\z/u,
      candidate,
      ""
    )
  end

  defp single_action_word?(label) do
    String.match?(label, ~r/\A[a-z]+(?:ed|en|ing)\z/u)
  end

  defp maybe_strip_question_prefix(candidate, 0) do
    Regex.replace(
      ~r/\A(?:should we|which|what|where|when|how|do we|does this|is this)\b.*?\b(?:on|for|between|around|about)\s+/iu,
      candidate,
      ""
    )
    |> then(&Regex.replace(~r/\Ashould\s+[a-z0-9_-]+\s+/iu, &1, ""))
  end

  defp maybe_strip_question_prefix(candidate, _index), do: candidate
end
