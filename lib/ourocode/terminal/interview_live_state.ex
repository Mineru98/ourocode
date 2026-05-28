defmodule Ourocode.Terminal.InterviewLiveState do
  @moduledoc """
  Reads interview-related values from a render result and its live pane snapshot.
  """

  alias Ourocode.Terminal.LiveResult

  @spec result(map()) :: map()
  def result(result), do: LiveResult.result(result)

  @spec interview(map()) :: map() | nil
  def interview(result) do
    case field(result(result), :interview) do
      %{} = interview -> normalize_interview(interview)
      _other -> nil
    end
  end

  @spec wonder_tool(map()) :: map() | nil
  def wonder_tool(result) do
    case field(result(result), :wonder_tool) do
      %{} = detection -> normalize_wonder_tool(detection)
      _other -> nil
    end
  end

  @spec interview_session(map()) :: map() | nil
  def interview_session(result) do
    case field(result(result), :interview_session) do
      %{} = session -> normalize_known_map(session, [:label, :parent_call_id, :round, :status])
      _other -> nil
    end
  end

  @spec paused?(map()) :: boolean()
  def paused?(result), do: field(result(result), :paused, false) == true

  defp normalize_interview(interview) do
    interview
    |> normalize_known_map([
      :ambiguity,
      :breakdown,
      :complete,
      :dialogue,
      :mcp_activity,
      :mcp_reasoning,
      :milestone,
      :parent_call_id,
      :question,
      :question_options,
      :reasoning,
      :router,
      :seed_ready,
      :session_id,
      :status,
      :waiting,
      :waiting_started_monotonic_ms
    ])
    |> normalize_dialogue()
    |> normalize_question_options()
  end

  defp normalize_dialogue(%{dialogue: dialogue} = interview) when is_list(dialogue) do
    Map.put(interview, :dialogue, Enum.map(dialogue, &normalize_dialogue_turn/1))
  end

  defp normalize_dialogue(interview), do: interview

  defp normalize_question_options(%{question_options: options} = interview)
       when is_list(options) do
    Map.put(interview, :question_options, Enum.map(options, &normalize_option/1))
  end

  defp normalize_question_options(interview), do: interview

  defp normalize_option(option) when is_map(option) do
    option
    |> normalize_known_map([:label, :description, :recommended?])
  end

  defp normalize_option(other), do: %{label: to_string(other), description: ""}

  defp normalize_dialogue_turn(turn) when is_map(turn) do
    %{
      role: normalize_role(field(turn, :role)),
      text: field(turn, :text, "")
    }
  end

  defp normalize_dialogue_turn(other), do: %{role: :unknown, text: other}

  defp normalize_role(role) when role in [:mcp, "mcp"], do: :mcp
  defp normalize_role(role) when role in [:main, "main"], do: :main
  defp normalize_role(role) when role in [:user, "user"], do: :user
  defp normalize_role(_role), do: :unknown

  defp normalize_wonder_tool(detection) do
    detection
    |> normalize_known_map([:parent_call_id, :request, :request_id])
    |> normalize_wonder_request()
  end

  defp normalize_wonder_request(%{request: request} = detection) when is_map(request) do
    questions =
      request
      |> normalize_known_map([:questions])
      |> Map.get(:questions, [])

    request =
      request
      |> normalize_known_map([:questions])
      |> Map.put(:questions, Enum.map(questions, &normalize_question/1))

    Map.put(detection, :request, request)
  end

  defp normalize_wonder_request(detection), do: detection

  defp normalize_question(question) when is_map(question) do
    normalize_known_map(question, [:id, :header, :question, :options, :round])
  end

  defp normalize_question(other), do: other

  defp normalize_known_map(map, keys) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      string_key = Atom.to_string(key)

      cond do
        Map.has_key?(acc, string_key) ->
          acc
          |> Map.put(key, Map.get(acc, string_key))
          |> Map.delete(string_key)

        Map.has_key?(acc, key) ->
          Map.delete(acc, string_key)

        true ->
          acc
      end
    end)
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      Map.has_key?(map, key) -> Map.get(map, key)
      true -> default
    end
  end

  defp field(_map, _key, default), do: default
end
