defmodule Ourocode.WonderTool.DecisionRequest do
  @moduledoc """
  Parser and validator for wonderTool multiple-choice decision requests.

  wonderTool is the ourocode UI name for checkpoints inspired by
  AskUserQuestion-style decision prompts: Socratic decisions, permissions, and
  clarifications. This module keeps the runtime-facing payload shape data-only
  so transports and plugin normalizers can validate requests before they are
  journaled or rendered.
  """

  alias Ourocode.WonderTool.DecisionRequest.Fields
  alias Ourocode.WonderTool.DecisionRequest.Questions

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
    payload = unwrap_payload_container(request)

    with :ok <- validate_tool_name(request, payload),
         request_kind = Questions.request_kind(payload),
         {:ok, questions} <- fetch_questions(payload),
         :ok <- validate_question_count(questions),
         {:ok, normalized_questions} <- Questions.normalize(questions, request_kind) do
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
  def decision_request?(request) when is_map(request), do: match?({:ok, _request}, parse(request))

  def decision_request?(_request), do: false

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

  defp first_map_field(map, keys) do
    Fields.map_field(map, keys)
  end

  defp map_field(map, keys), do: Fields.map_field(map, keys)

  defp string_field(map, keys), do: Fields.string_field(map, keys)

  defp first_field(map, keys), do: Fields.first(map, keys)

  defp maybe_put(map, key, value), do: Fields.put_present(map, key, value)
end
