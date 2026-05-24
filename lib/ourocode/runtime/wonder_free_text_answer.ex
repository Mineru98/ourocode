defmodule Ourocode.Runtime.WonderFreeTextAnswer do
  @moduledoc """
  Captures wonderTool free-text answers when option capture does not apply.
  """

  @spec capture(map(), term()) :: {:ok, map()} | {:error, :selection_required}
  def capture(request, selection) when is_map(request) do
    with text when is_binary(text) and text != "" <- selection_text(selection),
         %{} = question <- question(request, selection) do
      {:ok, decision(request, question, text)}
    else
      _other -> {:error, :selection_required}
    end
  end

  def capture(_request, _selection), do: {:error, :selection_required}

  @spec selection_text(term()) :: String.t() | nil
  def selection_text(selection) when is_map(selection) do
    selection
    |> first_present([
      "freeText",
      "free_text",
      "otherText",
      "other_text",
      :freeText,
      :free_text,
      :otherText,
      :other_text
    ])
    |> case do
      text when is_binary(text) -> String.trim(text)
      _other -> nil
    end
  end

  def selection_text(_selection), do: nil

  @spec question(map(), term()) :: map() | nil
  def question(request, selection) do
    questions = Map.get(request, :questions, [])
    requested_id = question_id(selection)

    cond do
      is_binary(requested_id) and requested_id != "" ->
        Enum.find(questions, &question_id_match?(&1, requested_id)) || List.first(questions)

      true ->
        List.first(questions)
    end
  end

  defp question_id(selection) when is_map(selection) do
    selection
    |> first_present([
      "questionId",
      "question_id",
      :questionId,
      :question_id
    ])
    |> case do
      id when is_binary(id) -> String.trim(id)
      _other -> nil
    end
  end

  defp question_id(_selection), do: nil

  defp question_id_match?(%{} = question, id) do
    (Map.get(question, :id) || Map.get(question, "id")) == id
  end

  defp question_id_match?(_question, _id), do: false

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp decision(request, question, text) do
    %{
      type: :wonder_decision,
      question_id: Map.get(question, :id) || Map.get(question, "id") || "free_answer",
      question_kind: Map.get(question, :kind) || Map.get(question, "kind"),
      selected_index: 0,
      selected_label: text,
      selected_description: "Free answer",
      selected_option: %{label: text, description: "Free answer", free_text?: true},
      free_text: text,
      selected_at_ms: System.system_time(:millisecond),
      request_id: Map.get(request, :request_id),
      child_id: Map.get(request, :child_id),
      parent_call_id: Map.get(request, :parent_call_id),
      external_ids: Map.get(request, :external_ids)
    }
  end
end
