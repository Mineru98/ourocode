defmodule Ourocode.WonderTool.SelectionHandler do
  @moduledoc """
  Captures wonderTool multiple-choice selections.

  A wonderTool decision answer selects exactly one option by default. Questions
  marked `multi_select?` may capture one or more selected options.
  The handler accepts normalized `Ourocode.WonderTool.DecisionRequest` data or a
  raw request payload that can be parsed by that module, then returns a
  journal-ready `wonder_decision` map.
  """

  alias Ourocode.WonderTool.DecisionRequest

  @type selection_payload :: map() | list() | integer() | String.t()

  @type wonder_decision :: %{
          required(:type) => :wonder_decision,
          required(:question_id) => String.t(),
          required(:question_kind) => atom() | nil,
          required(:selected_index) => pos_integer(),
          required(:selected_label) => String.t(),
          required(:selected_description) => String.t(),
          required(:selected_option) => DecisionRequest.option(),
          optional(:multi_select?) => boolean(),
          optional(:selected_indices) => [pos_integer()],
          optional(:selected_labels) => [String.t()],
          optional(:selected_descriptions) => [String.t()],
          optional(:selected_options) => [DecisionRequest.option()],
          optional(:selected_preview_placeholders) => [String.t()],
          optional(:free_text) => String.t(),
          optional(:annotation) => String.t(),
          required(:selected_at_ms) => integer(),
          optional(:request_id) => String.t(),
          optional(:child_id) => String.t(),
          optional(:parent_call_id) => String.t(),
          optional(:external_ids) => map()
        }

  @doc """
  Captures a selected option from a wonderTool decision request. Multi-select
  questions capture one or more selections.

  Selection payloads may use a singular `selected_option`/`selectedOption` value
  or a plural `selected_options`/`selectedOptions` list. A bare integer, string,
  or singleton list is also accepted for UI handlers that already know the
  active question.
  """
  @spec capture(map(), selection_payload(), keyword() | map()) ::
          {:ok, wonder_decision()} | {:error, term()}
  def capture(request, selection_payload, options \\ [])

  def capture(request, selection_payload, options) when is_map(request) do
    with {:ok, normalized_request} <- normalize_request(request),
         {:ok, question} <- resolve_question(normalized_request, selection_payload, options),
         {:ok, selections} <- normalize_selections(question, selection_payload),
         {:ok, selected} <- resolve_options(question, selections) do
      [{selected_index, selected_option} | _rest] = selected

      decision =
        %{
          type: :wonder_decision,
          question_id: question.id,
          question_kind: Map.get(question, :kind),
          selected_index: selected_index,
          selected_label: selected_label(selected),
          selected_description: selected_description(selected),
          selected_option: selected_option,
          selected_at_ms:
            options
            |> Map.new()
            |> Map.get(:selected_at_ms, System.system_time(:millisecond))
        }
        |> maybe_put_multi_select(question, selected)
        |> maybe_put(:selected_preview_placeholders, selected_preview_placeholders(selected))
        |> maybe_put(:free_text, free_text_from_payload(question, selected, selection_payload))
        |> maybe_put(:annotation, annotation_from_payload(selection_payload))
        |> maybe_put(:request_id, Map.get(normalized_request, :request_id))
        |> maybe_put(:child_id, Map.get(normalized_request, :child_id))
        |> maybe_put(:parent_call_id, Map.get(normalized_request, :parent_call_id))
        |> maybe_put(:external_ids, Map.get(normalized_request, :external_ids))

      {:ok, decision}
    end
  end

  def capture(_request, _selection_payload, _options), do: {:error, :request_must_be_map}

  defp normalize_request(%{tool: :wonder_tool, type: :multiple_choice_decision} = request) do
    {:ok, request}
  end

  defp normalize_request(request), do: DecisionRequest.parse(request)

  defp resolve_question(%{questions: [question]}, _selection_payload, _options),
    do: {:ok, question}

  defp resolve_question(%{questions: questions}, selection_payload, options)
       when is_list(questions) do
    question_id =
      question_id_from_payload(selection_payload) ||
        Map.new(options) |> Map.get(:question_id)

    cond do
      is_nil(question_id) ->
        {:error, :question_id_required}

      question = Enum.find(questions, &(Map.get(&1, :id) == question_id)) ->
        {:ok, question}

      true ->
        {:error, {:unknown_question_id, question_id}}
    end
  end

  defp resolve_question(_request, _selection_payload, _options), do: {:error, :questions_required}

  defp normalize_selections(question, selection_payload) do
    selections =
      case extract_selections(selection_payload) do
        [] -> other_selection_from_payload(question, selection_payload)
        values -> values
      end

    cond do
      selections == [] ->
        {:error, :selection_required}

      multi_select?(question) ->
        {:ok, selections}

      match?([_one], selections) ->
        {:ok, selections}

      true ->
        {:error, {:exactly_one_selection_required, length(selections)}}
    end
  end

  defp extract_selections(selection_payload) when is_map(selection_payload) do
    cond do
      present?(selection_payload, [
        "selected_option",
        "selectedOption",
        :selected_option,
        :selectedOption
      ]) ->
        selection_payload
        |> first_present_field([
          "selected_option",
          "selectedOption",
          :selected_option,
          :selectedOption
        ])
        |> elem(1)
        |> List.wrap()
        |> reject_blank_selections()

      present?(
        selection_payload,
        [
          "selected_options",
          "selectedOptions",
          "selections",
          :selected_options,
          :selectedOptions,
          :selections
        ]
      ) ->
        selection_payload
        |> first_present_field([
          "selected_options",
          "selectedOptions",
          "selections",
          :selected_options,
          :selectedOptions,
          :selections
        ])
        |> elem(1)
        |> list_selection_values()
        |> reject_blank_selections()

      true ->
        []
    end
  end

  defp extract_selections(selection_payload) when is_list(selection_payload) do
    reject_blank_selections(selection_payload)
  end

  defp extract_selections(selection_payload) do
    selection_payload
    |> List.wrap()
    |> reject_blank_selections()
  end

  defp other_selection_from_payload(question, selection_payload) do
    with text when is_binary(text) <- free_text_value(selection_payload),
         true <- String.trim(text) != "",
         %{label: label} <- other_option(question) do
      [label]
    else
      _other -> []
    end
  end

  defp list_selection_values(values) when is_list(values), do: values
  defp list_selection_values(nil), do: []
  defp list_selection_values(value), do: [value]

  defp reject_blank_selections(selections) do
    Enum.reject(selections, fn
      nil -> true
      value when is_binary(value) -> String.trim(value) == ""
      _value -> false
    end)
  end

  defp resolve_options(%{options: options}, selections) when is_list(options) do
    selections
    |> Enum.reduce_while({:ok, []}, fn selection, {:ok, acc} ->
      case resolve_option(options, selection) do
        {:ok, index, option} -> {:cont, {:ok, [{index, option} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} ->
        selected =
          selected
          |> Enum.reverse()
          |> Enum.uniq_by(fn {index, _option} -> index end)

        if selected == [], do: {:error, :selection_required}, else: {:ok, selected}

      error ->
        error
    end
  end

  defp resolve_options(_question, _selections), do: {:error, :options_required}

  defp resolve_option(options, selection) do
    options
    |> Enum.with_index(1)
    |> Enum.find(&option_matches_selection?(&1, selection))
    |> case do
      {option, index} -> {:ok, index, option}
      nil -> resolve_other_option(options, selection)
    end
  end

  defp resolve_other_option(options, selection) when is_binary(selection) do
    case Enum.find(Enum.with_index(options, 1), fn {option, _index} -> other_option?(option) end) do
      {option, index} -> {:ok, index, option}
      nil -> {:error, {:unknown_selected_option, selection}}
    end
  end

  defp resolve_other_option(_options, selection),
    do: {:error, {:unknown_selected_option, selection}}

  defp option_matches_selection?({_option, index}, selection) when is_integer(selection),
    do: index == selection

  defp option_matches_selection?({option, index}, selection) when is_binary(selection) do
    case Integer.parse(String.trim(selection)) do
      {parsed_index, ""} -> index == parsed_index
      _other -> normalize_label(Map.get(option, :label)) == normalize_label(selection)
    end
  end

  defp option_matches_selection?(_indexed_option, _selection), do: false

  defp question_id_from_payload(selection_payload) when is_map(selection_payload) do
    selection_payload
    |> string_field(["question_id", "questionId", :question_id, :questionId])
  end

  defp question_id_from_payload(_selection_payload), do: nil

  defp present?(map, keys), do: not is_nil(first_present_field(map, keys))

  defp first_present_field(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> {key, value}
        :error -> nil
      end
    end)
  end

  defp string_field(map, keys) do
    case first_present_field(map, keys) do
      {_key, value} when is_binary(value) ->
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

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(_label), do: nil

  defp multi_select?(question), do: Map.get(question, :multi_select?, false) == true

  defp other_option(%{options: options}) when is_list(options) do
    Enum.find(options, &other_option?/1)
  end

  defp other_option(_question), do: nil

  defp other_option?(option) when is_map(option) do
    Map.get(option, :other?, false) == true or
      normalize_label(Map.get(option, :label)) in ["other", "기타"]
  end

  defp other_option?(_option), do: false

  defp selected_label(selected), do: selected |> Enum.map(&elem(&1, 1).label) |> Enum.join(", ")

  defp selected_description(selected),
    do: selected |> Enum.map(&elem(&1, 1).description) |> Enum.join("; ")

  defp maybe_put_multi_select(decision, question, selected) do
    if multi_select?(question) do
      decision
      |> Map.put(:multi_select?, true)
      |> Map.put(:selected_indices, Enum.map(selected, &elem(&1, 0)))
      |> Map.put(:selected_labels, Enum.map(selected, &elem(&1, 1).label))
      |> Map.put(:selected_descriptions, Enum.map(selected, &elem(&1, 1).description))
      |> Map.put(:selected_options, Enum.map(selected, &elem(&1, 1)))
    else
      decision
    end
  end

  defp selected_preview_placeholders(selected) do
    selected
    |> Enum.flat_map(fn {_index, option} ->
      []
      |> maybe_cons(Map.get(option, :preview_placeholder))
      |> Kernel.++(Map.get(option, :preview_placeholders, []))
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      placeholders -> placeholders
    end
  end

  defp free_text_from_payload(question, selected, selection_payload) do
    text = free_text_value(selection_payload)

    cond do
      is_binary(text) and String.trim(text) != "" ->
        String.trim(text)

      Enum.any?(selected, fn {_index, option} -> other_option?(option) end) ->
        selection_payload
        |> case do
          value when is_binary(value) -> value
          _other -> nil
        end
        |> case do
          value when is_binary(value) ->
            if other_option(question) != nil and normalize_label(value) not in ["other", "기타"],
              do: String.trim(value)

          _other ->
            nil
        end

      true ->
        nil
    end
  end

  defp annotation_from_payload(selection_payload) when is_map(selection_payload) do
    selection_payload
    |> string_field([
      "annotation",
      "annotations",
      "note",
      "notes",
      "free_text_note",
      "freeTextNote",
      :annotation,
      :annotations,
      :note,
      :notes,
      :free_text_note,
      :freeTextNote
    ])
  end

  defp annotation_from_payload(_selection_payload), do: nil

  defp free_text_value(selection_payload) when is_map(selection_payload) do
    selection_payload
    |> string_field([
      "other_text",
      "otherText",
      "free_text",
      "freeText",
      "text",
      :other_text,
      :otherText,
      :free_text,
      :freeText,
      :text
    ])
  end

  defp free_text_value(_selection_payload), do: nil

  defp maybe_cons(list, value) when is_binary(value), do: [value | list]
  defp maybe_cons(list, _value), do: list

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
