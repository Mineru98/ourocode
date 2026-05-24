defmodule Ourocode.Runtime.LoopBindingState do
  @moduledoc """
  Owns the live state shape and renderer snapshot refresh for loop bindings.
  """

  alias Ourocode.Dashboard.{ChildSessionPanes, ParentMcpPane}
  alias Ourocode.Runtime.{ActivitySnapshot, OuroborosLogTailer, OuroborosSessionReasoning}

  @spec initial() :: map()
  def initial do
    %{
      inbox: :queue.new(),
      parent: ParentMcpPane.new(),
      child: ChildSessionPanes.new(),
      wonder: nil,
      interview: nil,
      interview_session: nil,
      interview_waiter: nil,
      mcp_daemon: nil,
      mcp_llm_backend: nil,
      workflow: %{},
      ouroboros_activity: [],
      ouroboros_log_offsets: %{},
      ouroboros_log_paths: [],
      paused: false
    }
  end

  @spec snapshot(pid(), pos_integer()) :: map()
  def snapshot(agent, activity_keep) when is_pid(agent) and is_integer(activity_keep) do
    {paths, offsets, session_id, has_reasoning?} =
      Agent.get(agent, fn state ->
        interview = state.interview || %{}

        {
          Map.get(state, :ouroboros_log_paths, []),
          Map.get(state, :ouroboros_log_offsets, %{}),
          Map.get(interview, :session_id),
          Map.get(interview, :mcp_reasoning, []) != []
        }
      end)

    {activity_lines, offsets} = OuroborosLogTailer.tail(paths, offsets)

    {session_reasoning, session_reasoning_state} =
      load_session_reasoning(session_id, has_reasoning?)

    activity_context = load_activity_context(session_id)

    Agent.get_and_update(agent, fn state ->
      state =
        ActivitySnapshot.refresh_activity(
          state,
          activity_lines,
          offsets,
          activity_context,
          activity_keep
        )

      state =
        refresh_ouroboros_session_reasoning(state, session_reasoning, session_reasoning_state)

      %{
        runtime: %{parent_panes: state.parent, child_panes: state.child},
        wonder_tool: state.wonder,
        interview: state.interview,
        interview_session: state.interview_session,
        paused: state.paused
      }
      |> then(&{&1, state})
    end)
  end

  defp load_session_reasoning(session_id, false) when is_binary(session_id),
    do: OuroborosSessionReasoning.load(session_id)

  defp load_session_reasoning(_session_id, _has_reasoning?), do: {[], %{}}

  defp load_activity_context(session_id) when is_binary(session_id),
    do: OuroborosSessionReasoning.load_activity_context(session_id)

  defp load_activity_context(_session_id), do: %{}

  defp refresh_ouroboros_session_reasoning(state, [], _reasoning_state), do: state

  defp refresh_ouroboros_session_reasoning(state, lines, reasoning_state) when is_list(lines) do
    ActivitySnapshot.refresh_session_reasoning(state, lines, reasoning_state)
  end
end
