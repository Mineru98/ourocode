defmodule Ourocode.Runtime.InterviewEvents do
  @moduledoc """
  Synthetic runtime events and state projections for the interview relay loop.
  """

  @spec answer_ack(map(), String.t(), integer()) :: map()
  def answer_ack(interview, text, occurred_at_ms \\ System.system_time(:millisecond)) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: Map.get(interview, :parent_call_id),
      child_id: Map.get(interview, :child_id),
      runtime_source: "ouroboros",
      occurred_at_ms: occurred_at_ms,
      payload: %{kind: :interview_answer, token: "you: " <> text}
    }
  end

  @spec question(String.t(), String.t(), map(), integer()) :: map()
  def question(parent_call_id, text, meta, occurred_at_ms \\ System.system_time(:millisecond)) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: occurred_at_ms,
      payload: %{"token" => text, "meta" => meta}
    }
  end

  @spec server_error(String.t(), String.t(), String.t() | nil, integer()) :: map()
  def server_error(
        parent_call_id,
        message,
        session_id,
        occurred_at_ms \\ System.system_time(:millisecond)
      ) do
    status = server_error_status(message)

    %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: occurred_at_ms,
      payload: %{
        "meta" => %{},
        kind: :interview_error,
        token: status <> resume_hint(session_id)
      }
    }
  end

  @spec complete(String.t(), atom(), integer()) :: map()
  def complete(parent_call_id, reason, occurred_at_ms \\ System.system_time(:millisecond)) do
    %{
      type: :child_event,
      event_type: :child_event,
      source: :interview,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: occurred_at_ms,
      payload: %{
        "meta" => %{"seed_ready" => true},
        kind: :interview_complete,
        token: "interview complete (#{reason}) — 📍 Next: ooo seed"
      }
    }
  end

  @spec failure(String.t(), term(), integer()) :: map()
  def failure(parent_call_id, reason, occurred_at_ms \\ System.system_time(:millisecond)) do
    %{
      type: :parent_call_failed,
      event_type: :parent_call_failed,
      source: :terminal_runtime,
      transport: :streamable_http,
      parent_call_id: parent_call_id,
      runtime_source: "ouroboros",
      occurred_at_ms: occurred_at_ms,
      payload: %{status: :failed, reason: inspect(reason)}
    }
  end

  @spec answer_state(map(), map(), String.t()) :: map()
  def answer_state(state, interview, text) do
    %{
      state
      | interview: Map.put(interview, :answered, text),
        interview_waiter: nil,
        paused: false
    }
  end

  @spec server_error_state(map(), String.t(), String.t() | nil) :: map()
  def server_error_state(state, message, session_id) do
    interview =
      (state.interview || %{})
      |> Map.put(:status, server_error_status(message))
      |> Map.put(:resumable, not is_nil(session_id))
      |> Map.delete(:answered)
      |> then(fn interview ->
        if is_nil(session_id), do: interview, else: Map.put(interview, :session_id, session_id)
      end)

    %{state | interview: interview, interview_waiter: nil}
  end

  @spec complete_state(map(), atom()) :: map()
  def complete_state(state, reason) do
    interview =
      (state.interview || %{})
      |> Map.put(:seed_ready, true)
      |> Map.put(:complete, reason)
      |> Map.put(:waiting, false)

    %{state | interview: interview, interview_session: nil, interview_waiter: nil}
  end

  @spec server_error_status(String.t()) :: String.t()
  def server_error_status(message), do: "MCP question generator unavailable: " <> message

  @spec resume_hint(String.t() | nil) :: String.t()
  def resume_hint(nil), do: ""
  def resume_hint(session_id), do: "  (session=#{session_id}, resume available)"
end
