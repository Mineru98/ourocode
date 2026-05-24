defmodule Ourocode.WonderTool.DecisionRequest.Questions do
  @moduledoc false

  alias Ourocode.WonderTool.DecisionRequest.Fields
  alias Ourocode.WonderTool.DecisionRequest.Options

  @known_kinds %{
    "socratic" => :socratic,
    "permission" => :permission,
    "clarification" => :clarification,
    "decision" => :decision
  }

  @spec request_kind(map()) :: atom() | nil
  def request_kind(payload) do
    Fields.first(payload, [
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

  @spec normalize([term()], atom() | nil) :: {:ok, [map()]} | {:error, term()}
  def normalize(questions, request_kind) when is_list(questions) do
    questions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {question, index}, {:ok, acc} ->
      case normalize_question(question, request_kind) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_question, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_question(question, request_kind) when is_map(question) do
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
         {:ok, options} <- Options.normalize(option_field(question)) do
      kind =
        Fields.first(question, ["kind", "decision_kind", :kind, :decision_kind])
        |> normalize_kind()
        |> infer_kind(request_kind, header)

      normalized =
        %{
          id: id,
          header: header,
          question: text,
          options: options
        }
        |> Fields.put_present(:kind, kind)
        |> Fields.put_present(:multi_select?, multi_select?(question))

      {:ok, normalized}
    end
  end

  defp normalize_question(_question, _request_kind), do: {:error, :question_must_be_map}

  defp required_string(map, keys, error) do
    case Fields.string_field(map, keys) do
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

    Map.get(@known_kinds, normalized)
  end

  defp normalize_kind(_kind), do: nil

  defp infer_kind(nil, nil, header), do: infer_kind_from_header(header)
  defp infer_kind(nil, request_kind, _header), do: request_kind
  defp infer_kind(kind, _request_kind, _header), do: kind

  defp infer_kind_from_header(header) do
    if header |> String.trim() |> String.downcase() == "permission" do
      :permission
    end
  end

  defp multi_select?(question) do
    question
    |> Fields.first([
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

  defp option_field(question) do
    Fields.first_present(question, ["options", "choices", :options, :choices])
  end

  defp truthy?(value) when value in [true, "true", "TRUE", "True", "1", 1], do: true
  defp truthy?(_value), do: false
end
