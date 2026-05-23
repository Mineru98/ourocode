defmodule Ourocode.WonderTool.InteractionDetector do
  @moduledoc """
  Detects runtime interactions that should be handled by wonderTool.

  The detector is intentionally data-only. It accepts decoded runtime payloads
  from any MCP transport, recognizes AskUserQuestion/request_user_input style
  multiple-choice checkpoints, and returns the normalized decision request plus
  compact routing metadata for panes and journal entries.
  """

  alias Ourocode.WonderTool.DecisionRequest

  @accepted_tool_names MapSet.new([
                         "wonderTool",
                         "wonder_tool",
                         "AskUserQuestion",
                         "request_user_input",
                         "requestUserInput",
                         "RequestUserInput"
                       ])

  @type detection :: %{
          required(:applicable?) => true,
          required(:tool) => :wonder_tool,
          required(:type) => :multiple_choice_checkpoint,
          required(:requires_socratic_checkpoint?) => true,
          required(:checkpoint_kinds) => [atom()],
          required(:question_count) => pos_integer(),
          required(:option_counts) => [pos_integer()],
          required(:request) => DecisionRequest.t(),
          optional(:request_id) => String.t(),
          optional(:child_id) => String.t(),
          optional(:parent_call_id) => String.t(),
          optional(:external_ids) => map()
        }

  @doc """
  Returns a wonderTool detection for applicable multiple-choice interactions.

  Non-wonderTool runtime events return `:ignore` so transport stream parsing can
  call this function without treating ordinary lifecycle events as failures.
  """
  @spec detect(term()) :: {:ok, detection()} | :ignore
  def detect(%{tool: :wonder_tool, type: :multiple_choice_decision} = payload) do
    case DecisionRequest.parse(payload) do
      {:ok, request} -> {:ok, detection(request)}
      {:error, _reason} -> :ignore
    end
  end

  def detect(payload) when is_map(payload) do
    if candidate_interaction?(payload) do
      case DecisionRequest.parse(payload) do
        {:ok, request} -> {:ok, detection(request)}
        {:error, _reason} -> :ignore
      end
    else
      :ignore
    end
  end

  def detect(_payload), do: :ignore

  @doc """
  Predicate form for fast routing checks.
  """
  @spec applicable?(term()) :: boolean()
  def applicable?(payload) do
    match?({:ok, _detection}, detect(payload))
  end

  defp detection(%{questions: questions} = request) do
    checkpoint_kinds =
      questions
      |> Enum.map(&Map.get(&1, :kind, :decision))
      |> Enum.uniq()

    %{
      applicable?: true,
      tool: :wonder_tool,
      type: :multiple_choice_checkpoint,
      requires_socratic_checkpoint?: true,
      checkpoint_kinds: checkpoint_kinds,
      question_count: length(questions),
      option_counts: Enum.map(questions, &length(&1.options)),
      request: request
    }
    |> maybe_put(:request_id, Map.get(request, :request_id))
    |> maybe_put(:child_id, Map.get(request, :child_id))
    |> maybe_put(:parent_call_id, Map.get(request, :parent_call_id))
    |> maybe_put(:external_ids, Map.get(request, :external_ids))
  end

  defp candidate_interaction?(payload) do
    payload
    |> tool_name_containers()
    |> Enum.any?(fn container ->
      container
      |> first_field(["tool", "tool_name", "name", :tool, :tool_name, :name])
      |> accepted_tool_name?()
    end)
  end

  defp tool_name_containers(payload) do
    [
      payload,
      first_map_field(payload, ["arguments", :arguments]),
      first_map_field(payload, ["params", :params]),
      first_map_field(payload, ["input", :input]),
      payload
      |> first_map_field(["params", :params])
      |> first_map_field(["arguments", :arguments]),
      payload |> first_map_field(["input", :input]) |> first_map_field(["arguments", :arguments])
    ]
    |> Enum.filter(&is_map/1)
  end

  defp accepted_tool_name?(name) when is_atom(name),
    do: name |> Atom.to_string() |> accepted_tool_name?()

  defp accepted_tool_name?(name) when is_binary(name),
    do: MapSet.member?(@accepted_tool_names, name)

  defp accepted_tool_name?(_name), do: false

  defp first_map_field(nil, _keys), do: nil

  defp first_map_field(map, keys) when is_map(map) do
    case first_field(map, keys) do
      value when is_map(value) -> value
      _other -> nil
    end
  end

  defp first_field(nil, _keys), do: nil

  defp first_field(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
