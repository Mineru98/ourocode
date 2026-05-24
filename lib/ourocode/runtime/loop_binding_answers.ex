defmodule Ourocode.Runtime.LoopBindingAnswers do
  @moduledoc """
  Applies user answers and cancellation actions to loop binding state.
  """

  alias Ourocode.Runtime.{InterviewEvents, WonderAnswer}

  @type enqueue_fun :: (pid(), map() -> :ok)

  @spec clear_wonder(pid()) :: :ok
  def clear_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :wonder, nil))
  end

  @spec pause_wonder(pid()) :: :ok
  def pause_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :paused, true))
  end

  @spec resume_wonder(pid()) :: :ok
  def resume_wonder(agent) when is_pid(agent) do
    Agent.update(agent, &Map.put(&1, :paused, false))
  end

  @spec answer_interview(pid(), String.t(), enqueue_fun()) ::
          {:ok, String.t()} | {:error, :no_active_interview}
  def answer_interview(agent, text, enqueue) when is_pid(agent) and is_binary(text) do
    case Agent.get(agent, &{&1.interview, Map.get(&1, :interview_waiter)}) do
      {%{} = interview, waiter} ->
        enqueue.(agent, InterviewEvents.answer_ack(interview, text))

        Agent.update(agent, fn state ->
          InterviewEvents.answer_state(state, interview, text)
        end)

        if is_pid(waiter), do: send(waiter, {:interview_answer, text})

        {:ok, text}

      {_none, _waiter} ->
        {:error, :no_active_interview}
    end
  end

  @spec answer_wonder(pid(), term(), enqueue_fun()) ::
          {:ok, map()} | {:error, :no_active_wonder | term()}
  def answer_wonder(agent, selection, enqueue) when is_pid(agent) do
    case Agent.get(agent, &{&1.wonder, Map.get(&1, :interview_waiter)}) do
      {%{request: request} = detection, waiter} ->
        case WonderAnswer.capture(request, selection) do
          {:ok, combined} ->
            enqueue.(agent, WonderAnswer.ack_event(detection, combined))
            clear_wonder(agent)

            if is_pid(waiter) do
              Agent.update(agent, &Map.put(&1, :interview_waiter, nil))
              send(waiter, {:interview_answer, combined.handback})
            end

            {:ok, combined.result}

          {:error, _reason} = error ->
            error
        end

      {_no_active, _waiter} ->
        {:error, :no_active_wonder}
    end
  end

  @spec cancel_wonder(pid(), String.t(), enqueue_fun()) ::
          {:ok, map()} | {:error, :no_active_wonder}
  def cancel_wonder(agent, reason, enqueue) when is_pid(agent) and is_binary(reason) do
    case Agent.get(agent, &{&1.wonder, Map.get(&1, :interview_waiter)}) do
      {%{} = detection, waiter} ->
        cancelled = WonderAnswer.cancelled(detection, reason)

        enqueue.(agent, WonderAnswer.cancel_event(detection, cancelled))

        Agent.update(agent, fn state ->
          %{
            state
            | wonder: nil,
              interview_waiter: nil,
              paused: false
          }
        end)

        if is_pid(waiter), do: send(waiter, {:interview_answer, "cancel"})

        {:ok, cancelled}

      {_no_active, _waiter} ->
        {:error, :no_active_wonder}
    end
  end
end
