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
  alias Ourocode.WonderTool.OptionSelection
  alias Ourocode.WonderTool.SelectionPayload

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
         {:ok, selections} <- OptionSelection.normalize(question, selection_payload),
         {:ok, selected} <- OptionSelection.resolve(question, selections) do
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
        |> maybe_put(:annotation, SelectionPayload.annotation(selection_payload))
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
      SelectionPayload.question_id(selection_payload) ||
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

  defp selected_label(selected), do: selected |> Enum.map(&elem(&1, 1).label) |> Enum.join(", ")

  defp selected_description(selected),
    do: selected |> Enum.map(&elem(&1, 1).description) |> Enum.join("; ")

  defp maybe_put_multi_select(decision, question, selected) do
    if OptionSelection.multi_select?(question) do
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
    text = SelectionPayload.free_text(selection_payload)

    cond do
      is_binary(text) and String.trim(text) != "" ->
        String.trim(text)

      Enum.any?(selected, fn {_index, option} -> OptionSelection.other_option?(option) end) ->
        selection_payload
        |> case do
          value when is_binary(value) -> value
          _other -> nil
        end
        |> case do
          value when is_binary(value) ->
            if OptionSelection.other_option(question) != nil and
                 OptionSelection.normalize_label(value) not in ["other", "기타"],
               do: String.trim(value)

          _other ->
            nil
        end

      true ->
        nil
    end
  end

  defp maybe_cons(list, value) when is_binary(value), do: [value | list]
  defp maybe_cons(list, _value), do: list

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
