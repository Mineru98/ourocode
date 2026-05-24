defmodule Ourocode.Runtime.InterviewProgress do
  @moduledoc """
  Updates live interview progress state for the terminal renderer.
  """

  alias Ourocode.Runtime.InterviewState

  @spec mark_dispatching(pid(), map(), String.t()) :: :ok
  def mark_dispatching(agent, task_request, parent_call_id) when is_pid(agent) do
    prompt = Map.get(task_request, :task_input, "")

    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      dialogue =
        case String.trim(prompt) do
          "" -> Map.get(prev, :dialogue, [])
          text -> InterviewState.prepend_dialogue_turn(Map.get(prev, :dialogue, []), :user, text)
        end

      iv =
        prev
        |> Map.merge(%{
          parent_call_id: parent_call_id,
          question: Map.get(prev, :question, ""),
          waiting: true,
          status: "starting interview session",
          dialogue: dialogue
        })
        |> Map.delete(:answered)

      session = %{
        parent_call_id: parent_call_id,
        label: "ooo interview",
        status: "starting interview session",
        round: 0
      }

      %{state | interview: iv, interview_session: session, paused: false}
    end)
  end

  @spec mark_waiting(pid(), map()) :: :ok
  def mark_waiting(agent, st) when is_pid(agent) do
    Agent.update(agent, fn state ->
      prev = state.interview || %{}

      iv =
        prev
        |> Map.merge(%{
          parent_call_id: st.parent_call_id || prev[:parent_call_id],
          question: Map.get(prev, :question, ""),
          waiting: true,
          status: waiting_status(st.round)
        })
        |> Map.delete(:answered)

      session = %{
        parent_call_id: st.parent_call_id,
        label: "ooo interview",
        status: waiting_status(st.round),
        round: st.round
      }

      %{state | interview: iv, interview_session: session, paused: false}
    end)
  end

  @spec waiting_status(pos_integer()) :: String.t()
  def waiting_status(1), do: "waiting for MCP interview question"
  def waiting_status(_round), do: "waiting for MCP follow-up question"
end
