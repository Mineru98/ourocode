defmodule Ourocode.WonderTool.SelectionPayload do
  @moduledoc """
  Extracts UI selection fields from wonderTool selection payloads.
  """

  @selection_keys [
    "selected_option",
    "selectedOption",
    :selected_option,
    :selectedOption
  ]

  @selection_list_keys [
    "selected_options",
    "selectedOptions",
    "selections",
    :selected_options,
    :selectedOptions,
    :selections
  ]

  @question_id_keys ["question_id", "questionId", :question_id, :questionId]

  @free_text_keys [
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
  ]

  @annotation_keys [
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
  ]

  @spec extract_selections(map() | list() | integer() | String.t()) :: list()
  def extract_selections(selection_payload) when is_map(selection_payload) do
    cond do
      present?(selection_payload, @selection_keys) ->
        selection_payload
        |> first_present_field(@selection_keys)
        |> elem(1)
        |> List.wrap()
        |> reject_blank_selections()

      present?(selection_payload, @selection_list_keys) ->
        selection_payload
        |> first_present_field(@selection_list_keys)
        |> elem(1)
        |> list_selection_values()
        |> reject_blank_selections()

      true ->
        []
    end
  end

  def extract_selections(selection_payload) when is_list(selection_payload) do
    reject_blank_selections(selection_payload)
  end

  def extract_selections(selection_payload) do
    selection_payload
    |> List.wrap()
    |> reject_blank_selections()
  end

  @spec question_id(map() | term()) :: String.t() | nil
  def question_id(selection_payload) when is_map(selection_payload) do
    string_field(selection_payload, @question_id_keys)
  end

  def question_id(_selection_payload), do: nil

  @spec free_text(map() | term()) :: String.t() | nil
  def free_text(selection_payload) when is_map(selection_payload) do
    string_field(selection_payload, @free_text_keys)
  end

  def free_text(_selection_payload), do: nil

  @spec annotation(map() | term()) :: String.t() | nil
  def annotation(selection_payload) when is_map(selection_payload) do
    string_field(selection_payload, @annotation_keys)
  end

  def annotation(_selection_payload), do: nil

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
end
