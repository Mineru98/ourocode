defmodule Ourocode.WonderTool.DecisionRequest.Options do
  @moduledoc """
  Normalizes and validates wonderTool multiple-choice options.
  """

  alias Ourocode.WonderTool.DecisionRequest.Fields

  @spec normalize({term(), term()} | nil) :: {:ok, [map()]} | {:error, term()}
  def normalize({field, options}) when is_list(options) do
    cond do
      length(options) < 2 -> {:error, :at_least_two_options_required}
      length(options) > 4 -> {:error, :at_most_four_options_allowed}
      true -> normalize_option_list(options, option_strings_allowed?(field))
    end
  end

  def normalize({_field, _options}), do: {:error, :options_must_be_list}
  def normalize(nil), do: {:error, :options_must_be_list}

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
        |> Fields.put_present(:other?, other_option?(option, label))
        |> Fields.put_present(
          :preview,
          Fields.string_field(option, ["preview", "summary", :preview, :summary])
        )
        |> Fields.put_present(
          :preview_placeholder,
          Fields.string_field(option, [
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
        |> Fields.put_present(:preview_placeholders, preview_placeholders(option))

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

  defp normalize_option(_option, _index, false), do: {:error, :option_must_be_map}
  defp normalize_option(_option, _index, true), do: {:error, :option_must_be_map_or_string}

  defp required_string(map, keys, error) do
    case Fields.string_field(map, keys) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp option_strings_allowed?(field), do: field in ["choices", :choices]

  defp recommended_label?(label) do
    String.ends_with?(label, "(Recommended)")
  end

  defp other_option?(option, label) do
    explicit =
      option
      |> Fields.first([
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
    |> Fields.first([
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

  defp truthy?(value) when value in [true, "true", "TRUE", "True", "1", 1], do: true
  defp truthy?(_value), do: false
end
