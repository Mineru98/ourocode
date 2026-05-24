defmodule Ourocode.Runtime.InterviewDialogue do
  @moduledoc """
  Transcript and routing-note transforms for live interview sessions.
  """

  alias Ourocode.Runtime.InterviewResponse

  @router_trace_keep 6
  @reasoning_keep 60
  @dialogue_keep 40

  @roles [:mcp, :main, :user]

  @spec add_router_trace(map(), String.t()) :: map()
  def add_router_trace(state, line) when is_map(state) and is_binary(line) do
    prev = Map.get(state, :interview) || %{}
    trace = [line | Map.get(prev, :router, [])] |> Enum.take(@router_trace_keep)
    Map.put(state, :interview, Map.put(prev, :router, trace))
  end

  @spec add_reasoning(map(), String.t()) :: map()
  def add_reasoning(state, chunk) when is_map(state) and is_binary(chunk) do
    prev = Map.get(state, :interview) || %{}
    buf = [chunk | Map.get(prev, :reasoning, [])] |> Enum.take(@reasoning_keep)
    Map.put(state, :interview, Map.put(prev, :reasoning, buf))
  end

  @spec add_dialogue(map(), atom(), String.t()) :: map()
  def add_dialogue(state, role, text) when role in @roles and is_binary(text) and is_map(state) do
    trimmed = String.trim(text)

    if trimmed == "" or (role == :main and leaked_router_prompt?(trimmed)) do
      state
    else
      prev = Map.get(state, :interview) || %{}
      log = prepend_turn(Map.get(prev, :dialogue, []), role, trimmed)

      interview =
        prev
        |> Map.put_new(:question, "")
        |> Map.put(:dialogue, log)

      Map.put(state, :interview, interview)
    end
  end

  @spec prepend_turn([map()], atom(), String.t()) :: [map()]
  def prepend_turn([%{role: role, text: text} | _] = log, role, text), do: log

  def prepend_turn(log, role, text) do
    [%{role: role, text: text} | log]
    |> Enum.take(@dialogue_keep)
  end

  @spec leaked_router_prompt?(term()) :: boolean()
  def leaked_router_prompt?(text) when is_binary(text) do
    flat = String.replace(text, ~r/\s+/, " ")

    String.contains?(flat, [
      "You are the answerer/router half",
      "Routing rules (from the interview SKILL)",
      "Tool protocol",
      "Output exactly one directive as the first line",
      "ANSWER [from-code] <answer>",
      "ASK_USER <question for the human>"
    ]) or
      (String.length(flat) > 900 and
         String.contains?(flat, "ANSWER [from-code]") and
         String.contains?(flat, "ASK_USER"))
  end

  def leaked_router_prompt?(_text), do: false

  @spec mcp_turn_text(term()) :: String.t()
  def mcp_turn_text(text) do
    case InterviewResponse.parse_ambiguity(text) do
      {:ok, score, question} when is_float(score) ->
        "(ambiguity #{:erlang.float_to_binary(score, decimals: 2)}) #{question}"

      _no_score ->
        String.trim(to_string(text))
    end
  end

  @spec ensure_answer_prefix(term(), term()) :: String.t()
  def ensure_answer_prefix(payload, source) do
    trimmed = String.trim(payload)

    if Regex.match?(~r/^\[from-[a-z]+\]/, trimmed),
      do: trimmed,
      else: "[from-#{source}] " <> trimmed
  end
end
