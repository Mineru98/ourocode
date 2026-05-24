defmodule Ourocode.Runtime.InterviewState do
  @moduledoc """
  Pure state transforms for the live Ouroboros interview transcript.
  """

  alias Ourocode.Runtime.{InterviewDialogue, InterviewResponse}

  @spec merge_question(map(), term(), term(), map(), term()) :: map()
  def merge_question(state, parent_call_id, text, meta, session_id) when is_map(state) do
    prev = Map.get(state, :interview) || %{}

    interview =
      prev
      |> Map.merge(%{
        question: InterviewResponse.question_from(text),
        parent_call_id: parent_call_id || prev[:parent_call_id],
        waiting: false
      })
      |> maybe_put(:session_id, session_id)
      |> maybe_put(:milestone, InterviewResponse.meta_value(meta, "milestone"))
      |> maybe_put(:seed_ready, InterviewResponse.meta_value(meta, "seed_ready"))
      |> Map.delete(:answered)

    state
    |> Map.put(:interview, interview)
    |> Map.put(:paused, false)
  end

  @spec add_router_trace(map(), String.t()) :: map()
  def add_router_trace(state, line) when is_map(state) and is_binary(line) do
    InterviewDialogue.add_router_trace(state, line)
  end

  @spec add_reasoning(map(), String.t()) :: map()
  def add_reasoning(state, chunk) when is_map(state) and is_binary(chunk) do
    InterviewDialogue.add_reasoning(state, chunk)
  end

  @spec add_dialogue(map(), atom(), String.t()) :: map()
  def add_dialogue(state, role, text) when is_binary(text) and is_map(state) do
    InterviewDialogue.add_dialogue(state, role, text)
  end

  @spec prepend_dialogue_turn([map()], atom(), String.t()) :: [map()]
  def prepend_dialogue_turn(log, role, text) do
    InterviewDialogue.prepend_turn(log, role, text)
  end

  @spec leaked_router_prompt?(term()) :: boolean()
  def leaked_router_prompt?(text), do: InterviewDialogue.leaked_router_prompt?(text)

  @spec mcp_turn_text(term()) :: String.t()
  def mcp_turn_text(text), do: InterviewDialogue.mcp_turn_text(text)

  @spec ensure_answer_prefix(term(), term()) :: String.t()
  def ensure_answer_prefix(payload, source),
    do: InterviewDialogue.ensure_answer_prefix(payload, source)

  @spec detect(map(), map()) :: map()
  def detect(state, event) when is_map(state) and is_map(event) do
    text = InterviewResponse.interview_text(event)
    meta = InterviewResponse.interview_meta(event)

    case InterviewResponse.parse_ambiguity(text) do
      {:ok, score, question} ->
        prev = Map.get(state, :interview) || %{}

        interview =
          prev
          |> Map.merge(%{
            question: InterviewResponse.clean_markdown(question),
            ambiguity: score,
            parent_call_id: Map.get(event, :parent_call_id) || prev[:parent_call_id],
            child_id: Map.get(event, :child_id) || prev[:child_id],
            waiting: false
          })
          |> merge_meta(meta)
          |> Map.delete(:answered)

        state
        |> Map.put(:interview, interview)
        |> Map.put(:paused, false)

      :none ->
        detect_from_meta(state, event, text, meta)
    end
  rescue
    _exception -> state
  end

  def detect(state, _event), do: state

  @spec merge_meta(map(), map()) :: map()
  def merge_meta(interview, meta) when is_map(interview) do
    interview
    |> maybe_put(:ambiguity, InterviewResponse.numeric_meta_value(meta, "ambiguity_score"))
    |> maybe_put(:milestone, InterviewResponse.meta_value(meta, "milestone"))
    |> maybe_put(:seed_ready, InterviewResponse.meta_value(meta, "seed_ready"))
    |> maybe_put(:breakdown, InterviewResponse.meta_value(meta, "ambiguity_breakdown"))
    |> maybe_put(:session_id, InterviewResponse.meta_value(meta, "session_id"))
    |> maybe_put(:mcp_reasoning, InterviewResponse.reasoning_lines(meta))
    |> maybe_put(:mcp_reasoning_state, InterviewResponse.meta_value(meta, "interview_reasoning"))
  end

  defp detect_from_meta(state, _event, _text, meta) when meta == %{}, do: state

  defp detect_from_meta(state, event, text, meta) do
    prev = Map.get(state, :interview)

    cond do
      prev ->
        Map.put(state, :interview, merge_meta(prev, meta))

      interview_meta?(meta) and String.trim(text) != "" ->
        interview =
          %{}
          |> Map.merge(%{
            question: InterviewResponse.clean_markdown(text),
            parent_call_id: Map.get(event, :parent_call_id),
            child_id: Map.get(event, :child_id),
            waiting: false
          })
          |> merge_meta(meta)
          |> Map.delete(:answered)

        state
        |> Map.put(:interview, interview)
        |> Map.put(:paused, false)

      true ->
        state
    end
  end

  defp interview_meta?(meta) when is_map(meta) do
    Enum.any?(
      ["internal_reasoning", "interview_reasoning", "ambiguity_score", "milestone", "seed_ready"],
      &(not is_nil(InterviewResponse.meta_value(meta, &1)))
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
