defmodule Ourocode.Runtime.LoopBindingInterviewSession do
  @moduledoc """
  Runs the live interview relay used by terminal loop bindings.
  """

  alias Ourocode.Runtime.{
    InterviewEvents,
    InterviewProgress,
    LoopBindingQuestionRouter,
    InterviewResponse,
    InterviewState,
    InterviewWonderPrompt,
    InterviewWorkflowInvocation,
    LoopBindingInterviewAwaiter,
    LoopBindingInterviewRound,
    LoopBindingRouterDecision,
    LoopBindingInterviewSessionConfig,
    LoopBindingInterviewText
  }

  alias Ourocode.Runtime.LoopBindingInterviewSessionIO, as: SessionIO

  @spec run(pid(), keyword(), keyword()) :: :ok
  def run(agent, opts, defaults) when is_pid(agent) and is_list(opts) and is_list(defaults) do
    session = LoopBindingInterviewSessionConfig.build(opts, defaults)

    push_initial_interview_prompt(agent, session.payload)
    interview_round(agent, session)
  rescue
    exception ->
      callbacks = Keyword.get(defaults, :callbacks, %{})

      enqueue_failure(
        agent,
        Keyword.get(opts, :parent_call_id, "parent-interview"),
        {:interview_loop_exception, Exception.message(exception)},
        callbacks
      )

      :ok
  end

  defp push_initial_interview_prompt(agent, payload) do
    case LoopBindingInterviewText.initial_context_from_payload(payload) do
      text when is_binary(text) and text != "" ->
        SessionIO.push_dialogue(agent, :user, text)

      _none ->
        :ok
    end
  end

  defp interview_round(agent, %{round: round, max_rounds: max, parent_call_id: pcid} = st)
       when round > max do
    SessionIO.enqueue_complete(agent, pcid, :max_rounds, st.callbacks)
    :ok
  end

  defp interview_round(agent, st) do
    InterviewProgress.mark_waiting(agent, st)

    case LoopBindingInterviewRound.action(st.pcf.(st.payload), st.session_id) do
      {:server_error, message, session_id} ->
        enqueue_server_error(agent, st.parent_call_id, message, session_id, st.callbacks)
        :ok

      {:complete, text, meta, session_id} ->
        SessionIO.merge_interview(
          agent,
          st.parent_call_id,
          text,
          meta,
          session_id
        )

        SessionIO.enqueue_complete(
          agent,
          st.parent_call_id,
          :seed_ready,
          st.callbacks
        )

        :ok

      {:question, question, text, meta, session_id} ->
        SessionIO.enqueue(
          agent,
          InterviewEvents.question(st.parent_call_id, text, meta),
          st.callbacks
        )

        SessionIO.merge_interview(
          agent,
          st.parent_call_id,
          text,
          meta,
          session_id
        )

        SessionIO.push_dialogue(
          agent,
          :mcp,
          InterviewState.mcp_turn_text(text)
        )

        route_question(agent, %{st | session_id: session_id}, question)

      :missing_session_id ->
        enqueue_failure(
          agent,
          st.parent_call_id,
          :interview_session_id_missing,
          st.callbacks
        )

        :ok

      {:transport_failed, reason} ->
        enqueue_failure(agent, st.parent_call_id, {:transport_failed, reason}, st.callbacks)
        :ok
    end
  end

  defp enqueue_server_error(agent, parent_call_id, message, session_id, callbacks) do
    status = InterviewEvents.server_error_status(message)

    SessionIO.enqueue(
      agent,
      InterviewEvents.server_error(parent_call_id, message, session_id),
      callbacks
    )

    Agent.update(agent, fn state ->
      InterviewEvents.server_error_state(state, message, session_id)
    end)

    SessionIO.push_dialogue(
      agent,
      :mcp,
      status <> InterviewEvents.resume_hint(session_id)
    )

    enqueue_failure(
      agent,
      parent_call_id,
      {:mcp_question_generator_unavailable, message, session_id},
      callbacks
    )

    :ok
  end

  defp route_question(agent, st, question) do
    question = InterviewResponse.clean_markdown(question)
    ctx = %{project_dir: st.project_dir, streak: st.streak}
    on_trace = fn line -> SessionIO.push_router_trace(agent, line) end
    on_reason = fn chunk -> SessionIO.push_reasoning(agent, chunk) end

    question
    |> LoopBindingQuestionRouter.decide(ctx, st.model, st.router_decision_timeout_ms,
      on_trace: on_trace,
      on_reason: on_reason
    )
    |> LoopBindingRouterDecision.action(question, st.streak)
    |> case do
      {:followup, payload_text, new_streak, dialogue_text} ->
        SessionIO.push_dialogue(agent, :main, dialogue_text)
        followup(agent, st, payload_text, new_streak)

      {:ask_user, prompt, options, :leaked_prompt} ->
        SessionIO.push_router_trace(
          agent,
          "router: discarded echoed prompt and asked user"
        )

        ask_user(agent, st, prompt, options)

      {:ask_user, prompt, options, :router} ->
        ask_user(agent, st, prompt, options)

      {:error, reason} ->
        enqueue_failure(agent, st.parent_call_id, {:router_failed, reason}, st.callbacks)
        :ok
    end
  end

  defp ask_user(agent, st, prompt, options) do
    SessionIO.push_dialogue(
      agent,
      :main,
      "→ asking you: " <> InterviewResponse.clean_markdown(prompt)
    )

    SessionIO.enqueue(
      agent,
      InterviewWonderPrompt.event(st.parent_call_id, st.round, prompt, options),
      st.callbacks
    )

    case LoopBindingInterviewAwaiter.await(agent, st.parent_call_id, prompt) do
      {:done, text} ->
        SessionIO.push_dialogue(agent, :user, text)
        SessionIO.enqueue_complete(agent, st.parent_call_id, :user_done, st.callbacks)
        :ok

      {:answer, user_text} ->
        SessionIO.push_dialogue(agent, :user, user_text)
        followup(agent, st, LoopBindingInterviewText.ensure_user_prefix(user_text), 0)
    end
  end

  defp followup(agent, st, answer_text, new_streak) do
    case InterviewWorkflowInvocation.build_followup_request_payload(
           st.session_id,
           answer_text,
           request_id: st.parent_call_id <> "-r" <> Integer.to_string(st.round)
         ) do
      {:ok, payload} ->
        interview_round(agent, %{
          st
          | payload: payload,
            round: st.round + 1,
            streak: new_streak
        })

      {:error, reason} ->
        enqueue_failure(
          agent,
          st.parent_call_id,
          {:followup_payload_failed, reason},
          st.callbacks
        )

        :ok
    end
  end

  defp enqueue_failure(agent, parent_call_id, reason, callbacks) do
    SessionIO.enqueue_failure(agent, parent_call_id, reason, callbacks)
  end
end
