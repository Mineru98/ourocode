defmodule Ourocode.Runtime.LoopBindingInterviewSessionIO do
  @moduledoc """
  Agent/event side effects used by the loop-binding interview session.
  """

  alias Ourocode.Runtime.{InterviewEvents, InterviewState}

  @spec merge_interview(pid(), String.t(), String.t(), map(), String.t() | nil) :: :ok
  def merge_interview(agent, parent_call_id, text, meta, session_id) do
    Agent.update(agent, fn state ->
      InterviewState.merge_question(state, parent_call_id, text, meta, session_id)
    end)
  end

  @spec push_router_trace(pid(), String.t()) :: :ok
  def push_router_trace(agent, line) when is_binary(line) do
    Agent.update(agent, fn state ->
      InterviewState.add_router_trace(state, line)
    end)
  end

  def push_router_trace(_agent, _line), do: :ok

  @spec push_reasoning(pid(), term()) :: :ok
  def push_reasoning(agent, chunk) when is_binary(chunk) do
    Agent.update(agent, fn state ->
      InterviewState.add_reasoning(state, chunk)
    end)
  end

  def push_reasoning(_agent, _chunk), do: :ok

  @spec push_dialogue(pid(), :mcp | :main | :user, String.t()) :: :ok
  def push_dialogue(agent, role, text)
      when role in [:mcp, :main, :user] and is_binary(text) do
    Agent.update(agent, fn state -> InterviewState.add_dialogue(state, role, text) end)
  end

  def push_dialogue(_agent, _role, _text), do: :ok

  @spec enqueue_complete(pid(), String.t(), atom(), map()) :: :ok
  def enqueue_complete(agent, parent_call_id, reason, callbacks) do
    enqueue(agent, InterviewEvents.complete(parent_call_id, reason), callbacks)

    Agent.update(agent, fn state ->
      InterviewEvents.complete_state(state, reason)
    end)

    push_dialogue(agent, :mcp, "interview complete (#{reason}) — next: ooo seed")
  end

  @spec enqueue_failure(pid(), String.t(), term(), map()) :: :ok
  def enqueue_failure(agent, parent_call_id, reason, callbacks) do
    enqueue(agent, InterviewEvents.failure(parent_call_id, reason), callbacks)
    :ok
  end

  @spec enqueue(pid(), map(), map()) :: :ok
  def enqueue(agent, event, %{enqueue: enqueue}) when is_function(enqueue, 2) do
    enqueue.(agent, event)
  end

  def enqueue(_agent, _event, _callbacks), do: :ok
end
