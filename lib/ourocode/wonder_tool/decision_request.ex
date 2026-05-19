defmodule Ourocode.WonderTool.DecisionRequest do
  @moduledoc """
  Parser and validator for wonderTool multiple-choice decision requests.

  wonderTool is the ourocode UI name for checkpoints inspired by
  AskUserQuestion-style decision prompts: Socratic decisions, permissions, and
  clarifications. This module keeps the runtime-facing payload shape data-only
  so transports and plugin normalizers can validate requests before they are
  journaled or rendered.
  """

  @type option :: %{
          required(:label) => String.t(),
          required(:description) => String.t(),
          optional(:recommended?) => boolean(),
          optional(:other?) => boolean(),
          optional(:preview) => String.t(),
          optional(:preview_placeholder) => String.t(),
          optional(:preview_placeholders) => [String.t()]
        }

  @type question :: %{
          required(:id) => String.t(),
          required(:header) => String.t(),
          required(:question) => String.t(),
          required(:options) => [option()],
          optional(:multi_select?) => boolean(),
          optional(:kind) => :socratic | :permission | :clarification | :decision
        }

  @type t :: %{
          required(:tool) => :wonder_tool,
          required(:type) => :multiple_choice_decision,
          required(:questions) => [question()],
          optional(:request_id) => String.t(),
          optional(:child_id) => String.t(),
          optional(:parent_call_id) => String.t(),
          optional(:external_ids) => map(),
          optional(:raw_request) => map()
        }

  @known_kinds MapSet.new(["socratic", "permission", "clarification", "decision"])
  @accepted_tool_names MapSet.new([
                         "wonderTool",
                         "wonder_tool",
                         "AskUserQuestion",
                         "request_user_input",
                         "requestUserInput",
                         "RequestUserInput"
                       ])

  @doc """
  Parses and validates a wonderTool/AskUserQuestion-style multiple-choice request.

  Accepted payloads may be wrapped in `"arguments"`, `"params"`, or `"input"`,
  including MCP `tools/call` envelopes where `"params"` carries the tool
  `"name"` and nested `"arguments"`.
  The top-level tool name may be `wonderTool`, `wonder_tool`,
  `request_user_input`, or the legacy `AskUserQuestion`.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%_{} = request), do: request |> Map.from_struct() |> parse()

  def parse(request) when is_map(request) do
    payload = request_payload(request)

    with :ok <- validate_tool_name(request, payload),
         request_kind = request_kind(payload),
         {:ok, questions} <- fetch_questions(payload),
         :ok <- validate_question_count(questions),
         {:ok, normalized_questions} <- normalize_questions(questions, request_kind) do
      normalized =
        %{
          tool: :wonder_tool,
          type: :multiple_choice_decision,
          questions: normalized_questions,
          raw_request: request
        }
        |> maybe_put(
          :request_id,
          string_field(payload, ["request_id", "requestId", :request_id, :requestId])
        )
        |> maybe_put(
          :child_id,
          string_field(payload, ["child_id", "childID", "childId", :child_id, :childID, :childId])
        )
        |> maybe_put(
          :parent_call_id,
          string_field(
            payload,
            ["parent_call_id", "parentCallId", :parent_call_id, :parentCallId]
          )
        )
        |> maybe_put(
          :external_ids,
          map_field(payload, ["external_ids", "externalIds", :external_ids, :externalIds])
        )

      {:ok, normalized}
    end
  end

  def parse(_request), do: {:error, :request_must_be_map}

  @doc """
  Returns true when a decoded runtime payload looks like a wonderTool decision.
  """
  @spec decision_request?(term()) :: boolean()
  def decision_request?(request) when is_map(request) do
    case parse(request) do
      {:ok, _request} -> true
      {:error, _reason} -> false
    end
  end

  def decision_request?(_request), do: false

  defp request_payload(request) do
    unwrap_payload_container(request)
  end

  defp validate_tool_name(request, payload) do
    tool_name =
      request
      |> tool_name_containers(payload)
      |> Enum.find_value(
        &string_field(&1, ["tool", "tool_name", "name", :tool, :tool_name, :name])
      )

    case tool_name do
      nil ->
        :ok

      name when is_binary(name) ->
        if MapSet.member?(@accepted_tool_names, name) do
          :ok
        else
          {:error, {:unsupported_tool, name}}
        end

      name ->
        {:error, {:unsupported_tool, name}}
    end
  end

  defp unwrap_payload_container(container) do
    cond do
      not is_map(container) ->
        container

      has_decision_fields?(container) ->
        container

      nested = first_map_field(container, ["arguments", :arguments]) ->
        unwrap_payload_container(nested)

      nested = first_map_field(container, ["params", :params]) ->
        unwrap_payload_container(nested)

      nested = first_map_field(container, ["input", :input]) ->
        unwrap_payload_container(nested)

      true ->
        container
    end
  end

  defp has_decision_fields?(container) do
    not is_nil(first_field(container, ["questions", :questions])) or
      has_question_fields?(container)
  end

  defp tool_name_containers(request, payload) do
    [
      request,
      first_map_field(request, ["arguments", :arguments]),
      first_map_field(request, ["params", :params]),
      first_map_field(request, ["input", :input]),
      payload
    ]
    |> Enum.filter(&is_map/1)
  end

  defp fetch_questions(payload) do
    case first_field(payload, ["questions", :questions]) do
      questions when is_list(questions) and questions != [] -> {:ok, questions}
      [] -> {:error, :questions_required}
      nil -> fetch_single_question(payload)
      _other -> {:error, :questions_must_be_list}
    end
  end

  defp fetch_single_question(payload) do
    if has_question_fields?(payload) do
      {:ok, [payload]}
    else
      {:error, :questions_required}
    end
  end

  defp has_question_fields?(payload) do
    not is_nil(first_field(payload, ["id", :id])) and
      not is_nil(first_field(payload, ["question", "prompt", :question, :prompt])) and
      not is_nil(first_field(payload, ["options", "choices", :options, :choices]))
  end

  defp validate_question_count(questions) do
    if length(questions) <= 3 do
      :ok
    else
      {:error, :at_most_three_questions_allowed}
    end
  end

  defp normalize_questions(questions, request_kind) do
    questions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {question, index}, {:ok, acc} ->
      case normalize_question(question, index, request_kind) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_question, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_question(question, _index, request_kind) when is_map(question) do
    with {:ok, id} <- required_string(question, ["id", :id], :id_required),
         :ok <- validate_question_id(id),
         {:ok, header} <- required_string(question, ["header", :header], :header_required),
         :ok <- validate_header(header),
         {:ok, text} <-
           required_string(
             question,
             ["question", "prompt", :question, :prompt],
             :question_required
           ),
         {:ok, options} <- normalize_options(option_field(question)) do
      kind =
        first_field(question, ["kind", "decision_kind", :kind, :decision_kind])
        |> normalize_kind()
        |> infer_kind(request_kind, header)

      normalized =
        %{
          id: id,
          header: header,
          question: text,
          options: options
        }
        |> maybe_put(:kind, kind)
        |> maybe_put(:multi_select?, multi_select?(question))

      {:ok, normalized}
    end
  end

  defp normalize_question(_question, _index, _request_kind), do: {:error, :question_must_be_map}

  defp normalize_options({field, options}) when is_list(options) do
    cond do
      length(options) < 2 -> {:error, :at_least_two_options_required}
      length(options) > 4 -> {:error, :at_most_four_options_allowed}
      true -> normalize_option_list(options, option_strings_allowed?(field))
    end
  end

  defp normalize_options({_field, _options}), do: {:error, :options_must_be_list}
  defp normalize_options(nil), do: {:error, :options_must_be_list}

  defp normalize_option_list(options, allow_string_options?) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, acc} ->
      case normalize_option(option, index, allow_string_options?) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_option, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_option(option, _index, _allow_string_options?) when is_map(option) do
    with {:ok, label} <- required_string(option, ["label", :label], :label_required),
         {:ok, description} <-
           required_string(option, ["description", :description], :description_required) do
      normalized =
        %{
          label: label,
          description: description,
          recommended?: recommended_label?(label)
        }
        |> maybe_put(:other?, other_option?(option, label))
        |> maybe_put(
          :preview,
          string_field(option, ["preview", "summary", :preview, :summary])
        )
        |> maybe_put(
          :preview_placeholder,
          string_field(option, [
            "preview_placeholder",
            "previewPlaceholder",
            "media_placeholder",
            "mediaPlaceholder",
            :preview_placeholder,
            :previewPlaceholder,
            :media_placeholder,
            :mediaPlaceholder
          ])
        )
        |> maybe_put(:preview_placeholders, preview_placeholders(option))

      {:ok, normalized}
    end
  end

  defp normalize_option(option, _index, true) when is_binary(option) do
    option = String.trim(option)

    if option == "" do
      {:error, :label_required}
    else
      {:ok, %{label: option, description: option, recommended?: recommended_label?(option)}}
    end
  end

  defp normalize_option(option, _index, false) when is_binary(option),
    do: {:error, :option_must_be_map}

  defp normalize_option(_option, _index, true), do: {:error, :option_must_be_map_or_string}
  defp normalize_option(_option, _index, false), do: {:error, :option_must_be_map}

  defp required_string(map, keys, error) do
    case string_field(map, keys) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp validate_question_id(id) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, id) do
      :ok
    else
      {:error, :id_must_be_snake_case}
    end
  end

  defp validate_header(header) do
    if String.length(header) <= 12 do
      :ok
    else
      {:error, :header_too_long}
    end
  end

  defp normalize_kind(nil), do: nil

  defp normalize_kind(kind) when is_atom(kind) do
    kind
    |> Atom.to_string()
    |> normalize_kind()
  end

  defp normalize_kind(kind) when is_binary(kind) do
    normalized = kind |> String.trim() |> String.downcase()

    if MapSet.member?(@known_kinds, normalized), do: String.to_atom(normalized)
  end

  defp normalize_kind(_kind), do: nil

  defp multi_select?(question) do
    question
    |> first_field([
      "multi_select",
      "multiSelect",
      "multiple",
      "allow_multiple",
      "allowMultiple",
      :multi_select,
      :multiSelect,
      :multiple,
      :allow_multiple,
      :allowMultiple
    ])
    |> truthy?()
  end

  defp truthy?(value) when value in [true, "true", "TRUE", "True", "1", 1], do: true
  defp truthy?(_value), do: false

  defp request_kind(payload) do
    first_field(payload, [
      "kind",
      "decision_kind",
      "interaction_kind",
      "interactionKind",
      "request_kind",
      "requestKind",
      :kind,
      :decision_kind,
      :interaction_kind,
      :interactionKind,
      :request_kind,
      :requestKind
    ])
    |> normalize_kind()
  end

  defp infer_kind(nil, nil, header), do: infer_kind_from_header(header)
  defp infer_kind(nil, request_kind, _header), do: request_kind
  defp infer_kind(kind, _request_kind, _header), do: kind

  defp infer_kind_from_header(header) do
    if header |> String.trim() |> String.downcase() == "permission" do
      :permission
    end
  end

  defp recommended_label?(label) do
    String.ends_with?(label, "(Recommended)")
  end

  defp other_option?(option, label) do
    explicit =
      option
      |> first_field([
        "other",
        "is_other",
        "isOther",
        "allow_free_text",
        "allowFreeText",
        :other,
        :is_other,
        :isOther,
        :allow_free_text,
        :allowFreeText
      ])
      |> truthy?()

    explicit or (label |> String.trim() |> String.downcase()) in ["other", "기타"]
  end

  defp preview_placeholders(option) do
    option
    |> first_field([
      "preview_placeholders",
      "previewPlaceholders",
      "media_placeholders",
      "mediaPlaceholders",
      :preview_placeholders,
      :previewPlaceholders,
      :media_placeholders,
      :mediaPlaceholders
    ])
    |> case do
      values when is_list(values) ->
        values
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> nil
          placeholders -> placeholders
        end

      _other ->
        nil
    end
  end

  defp first_map_field(map, keys) do
    case first_field(map, keys) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  defp option_field(question) do
    first_present_field(question, ["options", "choices", :options, :choices])
  end

  defp option_strings_allowed?(field), do: field in ["choices", :choices]

  defp map_field(map, keys) do
    case first_field(map, keys) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  defp string_field(map, keys) do
    case first_field(map, keys) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          trimmed -> trimmed
        end

      _other ->
        nil
    end
  end

  defp first_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp first_present_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> {key, value}
        :error -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
