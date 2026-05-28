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

    if option_list_text?(candidates) do
      candidates
      |> split_option_candidates()
      |> normalize_candidates()
      |> reject_fragmentary_choices()
    else
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

  defp option_list_text?(text) do
    text =~ ~r/\b(?:or|versus|vs\.?)\b/iu or
      text =~ ~r/(?:아니면|또는|혹은)/u or
      delimiter_count(text) >= 2
  end

  defp delimiter_count(text) do
    Regex.scan(~r/[,，、]/u, text) |> length()
  end

  defp trim_candidate(text) do
    Regex.replace(~r/\A[\s.!?;:]+|[\s.!?;:]+\z/u, text, "")
  end

  defp split_option_candidates(text) do
    text
    |> String.replace(~r/\b(?:or|versus|vs\.?)\b/iu, ",")
    |> String.replace(~r/\s*(?:아니면|또는|혹은)\s*/u, ",")
    |> String.split(~r/\s*[,，、]\s*/u)
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
    Regex.replace(~r/\Afor\s+[^,]+,\s*/iu, candidate, "")
  end

  defp context_only?(candidate) do
    String.match?(candidate, ~r/\Afor\s+[^,?.:]+\z/iu)
  end

  defp strip_question_stem(candidate) do
    Regex.replace(~r/\Ashould\s+the\s+interview\s+clarify\s+/iu, candidate, "")
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
